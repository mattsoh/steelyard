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
    TTL = ENV.fetch("HCB_TRANSACTION_CACHE_TTL", 120).to_i.seconds
    PAGE_SIZE = 100

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

      Rails.cache.fetch(cache_key, expires_in: TTL, race_condition_ttl: 10.seconds) { drain }
    end

    private

    def cache_key = "hcb:org:#{@organization_id}:transactions:v2:#{filters_cache_key}"

    def filters_cache_key
      @filters.to_a.sort_by(&:first).to_h.to_json
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
