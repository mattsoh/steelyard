module Hcb
  # Drains HCB's cursor-paginated transactions endpoint into one array per
  # organization and caches it, so the bulk, unpaginated JSON the frontend
  # expects doesn't mean hitting HCB on every request. The org-shared HCB
  # rate limit (1000 req / 5 min / IP) is the reason this exists at all.
  #
  # Drains the FULL history: the zero-balance cutoff and the ledger's running
  # balance are only correct when computed from the account's first
  # transaction, so a rolling window isn't an option here. Worst case for a
  # busy org is a few dozen requests per cache fill, well within budget.
  class OrganizationTransactions
    TTL = ENV.fetch("HCB_TRANSACTION_CACHE_TTL", 600).to_i.seconds
    PAGE_SIZE = 100

    # Once a cached entry is within this long of expiring, #all kicks off a
    # background redrain (WarmOrganizationTransactionsJob) instead of letting
    # it lapse -- so the next viewer's request is served from a warm cache
    # rather than blocking on a full multi-page HCB drain.
    REFRESH_AHEAD_WINDOW = 120.seconds

    def initialize(client, organization_id, filters: {})
      @client = client
      @organization_id = organization_id
      @filters = filters.compact.deep_stringify_keys
    end

    def page(after: nil, limit: PAGE_SIZE)
      @client.transactions(@organization_id, after: after, limit: limit, filters: @filters)
    end

    def all(bypass_cache: false)
      return drain if bypass_cache

      result = Rails.cache.fetch(cache_key, expires_in: TTL, race_condition_ttl: 10.seconds) do
        Rails.cache.write(fetched_at_key, Time.now, expires_in: TTL)
        drain
      end

      maybe_refresh_ahead
      result
    end

    # Drains fresh and unconditionally overwrites the cache, regardless of
    # what's currently in it. Used by WarmOrganizationTransactionsJob; unlike
    # bypass_cache: true above (which is for callers that always want a fresh
    # read and never touch the cache, e.g. the legacy importer) this is the
    # write side of cache warming.
    def refresh!
      result = drain
      Rails.cache.write(cache_key, result, expires_in: TTL)
      Rails.cache.write(fetched_at_key, Time.now, expires_in: TTL)
      result
    end

    # One HCB page per call, for callers that want to render transactions as
    # soon as each page resolves instead of blocking on the full multi-page
    # drain. Short-circuits to the cached #all result when it's already warm.
    #
    # Accumulates pages under a caller-supplied stream_id (rather than the
    # shared cache_key) so two concurrent drains -- two tabs, two users --
    # can't interleave and corrupt each other's buffer. Once the last page
    # comes back, the accumulated result is written to the same cache_key
    # #all reads, so the caller's next request for the fully-computed view
    # doesn't re-drain from scratch.
    def fetch_page(stream_id:, after: nil, limit: PAGE_SIZE)
      if after.blank?
        cached = Rails.cache.read(cache_key)
        return { data: cached, has_more: false, next_after: nil, total_count: cached.size } if cached
      end

      raw = page(after: after, limit: limit)
      data = raw["data"] || []
      has_more = data.any? && raw["has_more"]

      buffered = (Rails.cache.read(buffer_key(stream_id)) || []) + data

      if has_more
        Rails.cache.write(buffer_key(stream_id), buffered, expires_in: 2.minutes)
      else
        Rails.cache.write(cache_key, buffered, expires_in: TTL)
        Rails.cache.write(fetched_at_key, Time.now, expires_in: TTL)
        Rails.cache.delete(buffer_key(stream_id))
      end

      { data: data, has_more: has_more, next_after: has_more ? data.last["id"] : nil, total_count: raw["total_count"] }
    end

    private

    def buffer_key(stream_id) = "#{cache_key}:buffer:#{stream_id}"

    def cache_key = "hcb:org:#{@organization_id}:transactions:v2:#{filters_cache_key}"

    def fetched_at_key = "#{cache_key}:fetched_at"

    def refresh_lock_key = "#{cache_key}:refreshing"

    def filters_cache_key
      @filters.to_a.sort_by(&:first).to_h.to_json
    end

    # No-ops unless @client can identify who's asking (a real, logged-in
    # user's Hcb::Client) -- there's no local record of which users belong to
    # which HCB organization, so warming can only piggyback on real traffic.
    # The refresh_lock_key write is a compare-and-set: only the first request
    # to observe a stale-but-not-yet-expired cache enqueues the job.
    def maybe_refresh_ahead
      return unless @client.respond_to?(:user_id) && @client.user_id

      fetched_at = Rails.cache.read(fetched_at_key)
      return unless fetched_at
      return if Time.now - fetched_at < TTL - REFRESH_AHEAD_WINDOW
      return unless Rails.cache.write(refresh_lock_key, true, expires_in: REFRESH_AHEAD_WINDOW, unless_exist: true)

      WarmOrganizationTransactionsJob.perform_later(@client.user_id, @organization_id, filters: @filters)
    end

    def drain
      results = []
      after = nil

      loop do
        page = self.page(after: after, limit: PAGE_SIZE)
        data = page["data"] || []
        results.concat(data)

        break if data.empty? || !page["has_more"]

        after = data.last["id"]
      end

      results
    end
  end
end
