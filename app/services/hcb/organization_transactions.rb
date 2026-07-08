module Hcb
  # Drains HCB's cursor-paginated transactions endpoint into one array per
  # organization and caches it, so the bulk, unpaginated JSON the frontend
  # expects doesn't mean hitting HCB on every request. The org-shared HCB
  # rate limit (1000 req / 5 min / IP) is the reason this exists at all.
  #
  # Callers need the FULL history: the zero-balance cutoff and the ledger's
  # running balance are only correct when computed from the account's first
  # transaction, so a rolling window isn't an option for the *result*. But a
  # full re-walk of that history isn't needed on every redrain -- see
  # #incremental_drain, which pages forward from the newest transaction only
  # until it rejoins a previously-drained baseline, and splices the untouched
  # remainder back on. Cost then scales with recent activity, not with total
  # org history. Only a truly first-ever drain (or one where the baseline has
  # aged out after BASELINE_TTL of inactivity) pays the full-history cost.
  class OrganizationTransactions
    TTL = ENV.fetch("HCB_TRANSACTION_CACHE_TTL", 1800).to_i.seconds
    PAGE_SIZE = 100

    # Once the current cache entry is at least this old, #all kicks off a
    # background redrain (WarmOrganizationTransactionsJob) on top of serving
    # the (possibly slightly stale) cached result immediately -- so a viewer
    # who's been sitting on the page sees new HCB activity within roughly
    # this window, without every request paying for a live HCB round trip.
    # Deliberately much shorter than TTL: TTL bounds how stale data can get
    # before a request is forced to wait on a drain; this bounds how stale
    # it gets in the common case where background warming keeps up.
    BACKGROUND_REFRESH_INTERVAL = ENV.fetch("HCB_TRANSACTION_BACKGROUND_REFRESH_INTERVAL", 60).to_i.seconds

    # How many of the most-recently-seen transactions every redrain
    # unconditionally re-fetches from HCB, instead of trusting the previous
    # drain's copy. A transaction can still change after it's first seen
    # (declined, amount corrected) for some time, so anything older than this
    # window is treated as settled and safe to reuse as-is. This is a
    # generous safety margin, not a precise cutoff.
    SAFETY_OVERLAP = 300

    # How long a drain result is kept as the incremental-drain baseline, well
    # past TTL -- so a redrain triggered after an org has been quiet for a
    # while (primary cache already expired) still only walks recent activity
    # instead of the full history. Only an org that's never been drained
    # before (no baseline at all) pays the full-history cost.
    BASELINE_TTL = 7.days

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

      computed = false
      result = Rails.cache.fetch(cache_key, expires_in: TTL, race_condition_ttl: 10.seconds) do
        computed = true
        redrain
      end
      write_side_caches(result) if computed

      maybe_refresh_ahead
      result
    end

    # O(1) raw-transaction lookup by id, backed by #write_side_caches -- for
    # callers (OrganizationLedger#transaction_by_id) that only need one or two
    # specific transactions and shouldn't have to pay for materializing the
    # whole org history to get them. Returns nil on a cache miss (side caches
    # not yet warm for this drain); callers fall back to the slower path.
    #
    # Memoized per instance: callers like Api::TransactionsController#index
    # call this once per referenced match leg (dozens to hundreds of times in
    # one request), and Rails.cache.read deep-copies/deserializes the whole
    # by-id blob on every call -- without memoizing, that's the whole org's
    # transaction history re-deserialized once per referenced id.
    def find(id)
      by_id_cache&.dig(id)
    end

    # Chronological (oldest-first, declined-excluded) position/balance data
    # for the same drain result, keyed by #write_side_caches -- lets
    # OrganizationLedger answer "where does this id sit relative to the
    # cutoff" and "what are the zero-balance crossings" in O(1)/O(crossings)
    # instead of re-walking full org history per request. Returns nil on a
    # cache miss. Memoized per instance, same reasoning as #find above.
    def derived
      return @derived if defined?(@derived)
      @derived = Rails.cache.read(derived_key)
    end

    # Drains fresh and unconditionally overwrites the cache, regardless of
    # what's currently in it. Used by WarmOrganizationTransactionsJob; unlike
    # bypass_cache: true above (which is for callers that always want a fresh
    # read and never touch the cache, e.g. the legacy importer) this is the
    # write side of cache warming.
    def refresh!
      result = redrain
      Rails.cache.write(cache_key, result, expires_in: TTL)
      write_side_caches(result)
      result
    end

    # One HCB page per call, for callers that want to render transactions as
    # soon as each page resolves instead of blocking on the full multi-page
    # drain. Short-circuits to the cached #all result when it's already warm.
    #
    # When the primary cache has expired but a baseline is still around (see
    # #incremental_drain), the first call of a stream does the same
    # rejoin-with-baseline walk #redrain uses instead of raw-paging the
    # caller all the way back through full org history -- a page refresh
    # after the TTL lapses should only cost as much as recent activity, not
    # a full re-walk. That full walk is reserved for a truly first-ever
    # drain (no baseline at all).
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

        baseline = Rails.cache.read(baseline_key)
        if baseline.present?
          result = incremental_drain(baseline)
          Rails.cache.write(cache_key, result, expires_in: TTL)
          Rails.cache.write(baseline_key, result, expires_in: BASELINE_TTL)
          Rails.cache.write(fetched_at_key, Time.now, expires_in: TTL)
          Rails.cache.delete(buffer_key(stream_id))
          write_side_caches(result)
          return { data: result, has_more: false, next_after: nil, total_count: result.size }
        end
      end

      raw = page(after: after, limit: limit)
      data = raw["data"] || []
      has_more = data.any? && raw["has_more"]

      buffered = (Rails.cache.read(buffer_key(stream_id)) || []) + data

      if has_more
        Rails.cache.write(buffer_key(stream_id), buffered, expires_in: 2.minutes)
      else
        Rails.cache.write(cache_key, buffered, expires_in: TTL)
        Rails.cache.write(baseline_key, buffered, expires_in: BASELINE_TTL)
        Rails.cache.write(fetched_at_key, Time.now, expires_in: TTL)
        Rails.cache.delete(buffer_key(stream_id))
        write_side_caches(buffered)
      end

      { data: data, has_more: has_more, next_after: has_more ? data.last["id"] : nil, total_count: raw["total_count"] }
    end

    private

    def buffer_key(stream_id) = "#{cache_key}:buffer:#{stream_id}"

    def cache_key = "hcb:org:#{@organization_id}:transactions:v2:#{filters_cache_key}"

    def by_id_key = "#{cache_key}:by_id"

    def derived_key = "#{cache_key}:derived"

    def baseline_key = "#{cache_key}:baseline"

    def fetched_at_key = "#{cache_key}:fetched_at"

    def refresh_lock_key = "#{cache_key}:refreshing"

    def filters_cache_key
      @filters.to_a.sort_by(&:first).to_h.to_json
    end

    def by_id_cache
      return @by_id_cache if defined?(@by_id_cache)
      @by_id_cache = Rails.cache.read(by_id_key)
    end

    # Computed once per drain (see the three write sites above), not per
    # request -- this is the O(n) walk that used to happen fresh inside
    # OrganizationLedger on every single request that needed a lookup or
    # cutoff classification.
    def write_side_caches(result)
      Rails.cache.write(by_id_key, result.index_by { |t| t["id"] }, expires_in: TTL)

      ordered = result.reject { |t| t["declined"] }.reverse
      position_by_id = {}
      ids = Array.new(ordered.size)
      dates = Array.new(ordered.size)
      balances_cents = Array.new(ordered.size)
      running = 0

      ordered.each_with_index do |t, i|
        running += (t["amount_cents"] || 0)
        position_by_id[t["id"]] = i
        ids[i] = t["id"]
        dates[i] = t["date"]
        balances_cents[i] = running
      end

      Rails.cache.write(derived_key, {
        position_by_id: position_by_id,
        ids: ids,
        dates: dates,
        balances_cents: balances_cents
      }, expires_in: TTL)
    end

    # No-ops unless @client can identify who's asking (a real, logged-in
    # user's Hcb::Client) -- there's no local record of which users belong to
    # which HCB organization, so warming can only piggyback on real traffic.
    # The refresh_lock_key write is a compare-and-set: only the first request
    # to observe a due-for-a-check cache enqueues the job; everyone else
    # within the interval just gets served the current cache.
    def maybe_refresh_ahead
      return unless @client.respond_to?(:user_id) && @client.user_id

      fetched_at = Rails.cache.read(fetched_at_key)
      return unless fetched_at
      return if Time.now - fetched_at < BACKGROUND_REFRESH_INTERVAL
      return unless Rails.cache.write(refresh_lock_key, true, expires_in: BACKGROUND_REFRESH_INTERVAL, unless_exist: true)

      WarmOrganizationTransactionsJob.perform_later(@client.user_id, @organization_id, filters: @filters)
    end

    # Shared by #all's cache-miss path and #refresh!: incrementally redrains
    # against whatever baseline we have (falling back to a full #drain when
    # there isn't one), then re-saves the result as the new baseline.
    def redrain
      result = incremental_drain(Rails.cache.read(baseline_key))
      Rails.cache.write(baseline_key, result, expires_in: BASELINE_TTL)
      Rails.cache.write(fetched_at_key, Time.now, expires_in: TTL)
      result
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

    # Pages forward from the newest transaction only until we've re-fetched
    # at least SAFETY_OVERLAP transactions *and* landed back on a transaction
    # id already present in `previous` -- everything `previous` has beyond
    # that point is old enough to trust unchanged, so it's reused rather than
    # re-walked. Falls back to a full #drain when there's no baseline to
    # splice onto, or naturally degrades to one (via the has_more/empty-page
    # break) if the org's entire history is smaller than SAFETY_OVERLAP or
    # `previous` doesn't overlap with what HCB returns now at all.
    def incremental_drain(previous)
      return drain if previous.blank?

      previous_index = previous.each_with_index.to_h { |t, i| [ t["id"], i ] }
      fresh = []
      after = nil

      loop do
        page = self.page(after: after, limit: PAGE_SIZE)
        data = page["data"] || []
        break if data.empty?

        fresh.concat(data)

        if fresh.size >= SAFETY_OVERLAP
          rejoin_at = previous_index[fresh.last["id"]]
          return fresh + previous[(rejoin_at + 1)..] if rejoin_at
        end

        break unless page["has_more"]

        after = data.last["id"]
      end

      fresh
    end
  end
end
