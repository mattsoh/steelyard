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

    # How many of the SAFETY_OVERLAP pages a redrain asks HCB for at once.
    #
    # Cursor pagination is serial by nature -- page N+1 needs an id from page N
    # -- which is why a redrain used to cost SAFETY_OVERLAP / PAGE_SIZE round
    # trips in sequence. But on a *re*drain we already hold the previous drain,
    # so we already know the ids sitting at each page boundary, and can ask for
    # every page of the overlap window at the same time instead of waiting to be
    # told each cursor. See #parallel_incremental_drain.
    #
    # Capped, and deliberately low, because a page is expensive on HCB's side in
    # a way its size doesn't suggest: api/v4 paginates in Ruby, loading the
    # organization's *entire* transaction history and then slicing the requested
    # window out of it (Api::V4::Pagination#paginate_cursor). Every page costs
    # HCB a full-history load, so the fan-out is bounded to keep this app from
    # turning one viewer's page refresh into a burst of them. It also shares the
    # 1000-request / 5-minute per-IP budget with the whole userbase.
    MAX_CONCURRENT_PAGES = ENV.fetch("HCB_MAX_CONCURRENT_PAGES", 4).to_i

    # How many of the newest transactions a #sync_head! peek pulls from HCB.
    # One page, so answering "has anything landed since the last drain?" costs
    # a single HCB request -- where a redrain has to re-fetch SAFETY_OVERLAP
    # transactions before it can even start looking for its rejoin point.
    PEEK_SIZE = ENV.fetch("HCB_TRANSACTION_PEEK_SIZE", 100).to_i

    # How long a drain result is kept as the incremental-drain baseline, well
    # past TTL -- so a redrain triggered after an org has been quiet for a
    # while (primary cache already expired) still only walks recent activity
    # instead of the full history. Only an org that's never been drained
    # before (no baseline at all) pays the full-history cost.
    BASELINE_TTL = 7.days

    # How long a claimed full reload blocks another one from being queued --
    # comfortably longer than a full-history drain takes, since the point is to
    # stop a second one being queued *while the first is still running*. The
    # claim is released as soon as the drain lands, so this only matters if
    # whoever held it died without ever finishing.
    FULL_RELOAD_LOCK_TTL = 15.minutes

    # How long a browser-driven full reload can go without asking for a page
    # before the fallback job stops waiting and finishes the drain itself.
    #
    # A full reload is streamed to whoever asked for it (see #fetch_page's
    # reload mode) so they can watch it arrive rather than a spinner, and every
    # page it pulls touches the claim. That heartbeat is the difference between
    # "still being driven" and "the tab is gone": generous enough to cover one
    # slow page against a large organization, short enough that an abandoned
    # reload is picked up rather than lost.
    FULL_RELOAD_HEARTBEAT_TIMEOUT = ENV.fetch("HCB_FULL_RELOAD_HEARTBEAT_TIMEOUT", 90).to_i.seconds

    # What #refresh_one! hands back: the same transaction as the cache had it
    # and as HCB has it now, for callers that want to report what changed.
    RefreshedTransaction = Struct.new(:previous, :current, keyword_init: true)

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

      result = cached_result
      unless result
        computed = false
        result = Rails.cache.fetch(cache_key, expires_in: TTL, race_condition_ttl: 10.seconds) do
          computed = true
          redrain
        end
        computed ? publish(result) : LocalCache.write(cache_key, version_token, result)
      end

      maybe_refresh_ahead
      result
    end

    # O(1) raw-transaction lookup by id, backed by #write_side_caches -- for
    # callers (OrganizationLedger#transaction_by_id) that only need one or two
    # specific transactions and shouldn't have to pay for materializing the
    # whole org history to get them. Returns nil on a cache miss (side caches
    # not yet warm for this drain); callers fall back to the slower path.
    #
    # Memoized (see #memoized): callers like Api::MatchesController call this
    # once per referenced match leg (dozens to hundreds of times in one
    # request), and Rails.cache.read deep-copies/deserializes the whole by-id
    # blob on every call -- without memoizing, that's the whole org's
    # transaction history re-deserialized once per referenced id.
    def find(id)
      by_id_cache&.dig(id)
    end

    # Each drained transaction already rendered to its response JSON, keyed by
    # id -- the same fragment Api::TransactionsController#index used to build
    # per request by wrapping every raw hash in a TransactionPresenter and
    # calling #as_json on it. Computed once per drain (see #write_side_caches)
    # so a warm request assembles its response by joining strings instead of
    # re-presenting and re-serializing the org's whole working set.
    #
    # Covers the full drain, declined transactions included, so it can answer
    # for exactly the ids #find can. Returns nil on a cache miss; callers fall
    # back to presenting the raw transaction themselves.
    def presented = memoized(presented_key) { Rails.cache.read(presented_key) }

    # Display order for the full-history ledger view (Api::LedgerController):
    # every drained id sorted by the date the ledger *shows* -- when the
    # transaction was sent, which only TransactionPresenter knows how to work
    # out -- with the amount and declined flag each row needs to carry the
    # running balance forward. Same reasoning as #presented: sorting the whole
    # org history by a presenter-derived key is drain-time work, not
    # once-per-request work. Returns nil on a cache miss.
    def ledger_order = memoized(ledger_order_key) { Rails.cache.read(ledger_order_key) }

    # Chronological (oldest-first, declined-excluded) position/balance data
    # for the same drain result, keyed by #write_side_caches -- lets
    # OrganizationLedger answer "where does this id sit relative to the
    # cutoff" and "what are the zero-balance crossings" in O(1)/O(crossings)
    # instead of re-walking full org history per request. Returns nil on a
    # cache miss. Memoized, same reasoning as #find above.
    def derived = memoized(derived_key) { Rails.cache.read(derived_key) }

    # Drains fresh and unconditionally overwrites the cache, regardless of
    # what's currently in it. Used by WarmOrganizationTransactionsJob; unlike
    # bypass_cache: true above (which is for callers that always want a fresh
    # read and never touch the cache, e.g. the legacy importer) this is the
    # write side of cache warming.
    def refresh!
      publish(redrain)
    end

    # Full-history redrain that ignores the baseline entirely: every page is
    # re-fetched from HCB rather than paging forward only to a rejoin point. So
    # it costs one HCB request per PAGE_SIZE transactions of *total* org
    # history, where #refresh! costs one per PAGE_SIZE of recent activity --
    # which is why the UI warns before asking for it. It exists for the case an
    # incremental drain can't heal on its own: a transaction that changed
    # further back than SAFETY_OVERLAP reaches, so every redrain keeps splicing
    # the stale copy back on.
    def reload!
      publish(drain)
    end

    # Re-fetches ONE transaction from HCB and splices it into the cached drain
    # in place. A transaction isn't frozen once drained -- a pending card charge
    # settles at a different amount, a transfer is reversed, a memo is edited --
    # and neither #sync_head! (newest page only) nor #refresh! (SAFETY_OVERLAP
    # window) can see a change to an older one. This is the cheap targeted
    # answer: a single HCB request for the single transaction someone is
    # looking at.
    #
    # Returns nil for an id that isn't part of this organization's drained
    # history -- which is also the only case where nothing is written, since
    # splicing an arbitrary id into an org's cache on request would let a
    # caller put another org's transaction in it.
    def refresh_one!(id)
      current = cached_result || all
      index = current.index { |t| t["id"] == id }
      return nil if index.nil?

      fresh = @client.transaction(id)
      return RefreshedTransaction.new(previous: current[index], current: current[index]) if fresh.blank? || fresh["id"] != id

      previous = current[index]
      updated = current.dup
      updated[index] = fresh
      publish(updated)
      # OrganizationLedger keeps its own long-lived per-id copy for ids that
      # aren't in the drain; drop it so it can't shadow what we just re-fetched.
      Rails.cache.delete(OrganizationLedger.single_transaction_cache_key(@organization_id, id))

      RefreshedTransaction.new(previous: previous, current: fresh)
    end

    # Compare-and-set claim on the (expensive, org-shared) full reload, so two
    # people mashing the button -- or one person with two tabs open -- can't
    # queue two full-history drains against the rate limit at once. The loser
    # just watches the winner's drain land, which is the same result.
    #
    # The claim names the stream that owns it, which is what stops a full
    # re-walk from being something any caller can ask for at will: reload mode
    # is only honoured for the stream_id recorded here (see
    # #full_reload_stream?), so the drain the winner is being served can't be
    # started a second time alongside it.
    def claim_full_reload!(stream_id)
      Rails.cache.write(
        full_reload_lock_key,
        { stream_id: stream_id, touched_at: Time.now },
        expires_in: FULL_RELOAD_LOCK_TTL, unless_exist: true
      )
    end

    def release_full_reload! = Rails.cache.delete(full_reload_lock_key)

    def full_reload_claim = Rails.cache.read(full_reload_lock_key)

    # Whether this stream is the one holding the current claim, and so may ask
    # for reload-mode pages.
    def full_reload_stream?(stream_id)
      claim = full_reload_claim
      claim.is_a?(Hash) && stream_id.present? && claim[:stream_id] == stream_id
    end

    # Finishes a full reload whose browser stopped driving it -- the fallback
    # behind #fetch_page's reload mode, run from
    # WarmOrganizationTransactionsJob.
    #
    # Streaming a reload to the tab that asked for it is what makes it watchable
    # instead of a blank page for minutes, but it also means the drain only
    # progresses while that tab is open. This is the other half: the pages the
    # stream already fetched are sitting in its buffer, so finishing means
    # picking up from the last one rather than starting the walk again.
    #
    #   :done     -- the claim is gone, so the stream published and released it
    #   :running  -- still being driven; the caller should check back rather
    #                than drain alongside it and spend the rate limit twice
    #   :resumed  -- taken over and published from here
    def resume_full_reload!(stream_id)
      claim = full_reload_claim
      return :done if claim.nil?
      return :running if claim.is_a?(Hash) && claim[:touched_at] && Time.now - claim[:touched_at] < FULL_RELOAD_HEARTBEAT_TIMEOUT

      buffered = Rails.cache.read(buffer_key(stream_id)) || []
      publish(buffered + drain(after: buffered.last && buffered.last["id"]))
      Rails.cache.delete(buffer_key(stream_id))
      release_full_reload!
      :resumed
    end

    # Cheap "did anything land on HCB since the last drain?" check, for a page
    # load or an explicit user-triggered refresh. Pulls just one page -- the
    # newest PEEK_SIZE transactions, incoming and outgoing alike -- which is
    # enough to answer the question, and in the common case (the answer being "a
    # couple of new ones") enough to fix the cache in place without a redrain.
    #
    # Returns:
    #   :fresh  -- HCB's newest page already matches the cache; nothing written
    #   :synced -- everything that changed fit inside the peek, so it has been
    #              spliced into the cache and every reader sees it now
    #   :deep   -- nothing cached to compare against, or more changed than one
    #              page can account for; the caller should fall back to a full
    #              redrain (WarmOrganizationTransactionsJob, in the background)
    def sync_head!
      cached = cached_result
      return :deep if cached.blank?

      head = page(limit: PEEK_SIZE)["data"] || []
      return :fresh if head.empty?

      # Where HCB's newest page rejoins the cache. Both lists are newest-first,
      # so head.last is the *oldest* transaction in the peek.
      rejoin_at = cached.index { |t| t["id"] == head.last["id"] }

      # Not in the cache at all: either more than PEEK_SIZE transactions have
      # landed since the last drain, or the cache diverges in a way one page
      # can't explain. Needs a real redrain to splice safely.
      return :deep if rejoin_at.nil?

      # If nothing were new, the peek would line up exactly with the head of the
      # cache, so its oldest transaction would sit at index head.size - 1.
      # Anything shallower than that is new transactions pushing it down; a
      # *deeper* rejoin means transactions the cache has are gone from HCB's
      # newest page, which one page can't explain either.
      new_count = head.size - 1 - rejoin_at
      return :deep if new_count.negative?
      return :fresh if new_count.zero? && head == cached[0, head.size]

      # head is authoritative for its whole span, not just for the new rows, so
      # this also picks up in-place changes to already-seen transactions inside
      # the peek (one going declined, an amount corrected) -- the same thing
      # SAFETY_OVERLAP exists to catch on a full redrain.
      publish(head + cached[(rejoin_at + 1)..])
      :synced
    end

    # Cache-only snapshot of how current the drain is, so a client can poll a
    # background redrain's progress without spending an HCB request per poll.
    # fetched_at advances exactly when a new result is published, which is the
    # signal a caller waiting on #sync_head!'s :deep case watches for.
    def sync_state
      { fetched_at: stamp && stamp[:at].to_f, count: stamp && stamp[:count] }
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
    # `reload: true` is the user-requested full reload being streamed rather
    # than waited on: it skips both short-circuits above -- the cached result
    # and the baseline are exactly what someone reaching for a full reload has
    # decided not to trust -- and raw-pages the whole history into the stream's
    # buffer, publishing only once the last page lands. So the tab that asked
    # watches rows arrive instead of sitting on a cleared page for minutes,
    # while a partial walk still never becomes the authoritative result.
    #
    # Every reload page touches the claim, which is what lets
    # #resume_full_reload! tell a stream still being driven from a closed tab.
    # Callers must check #full_reload_stream? first; reload mode is only for the
    # stream holding the claim.
    def fetch_page(stream_id:, after: nil, limit: PAGE_SIZE, reload: false)
      if reload
        touch_full_reload!(stream_id)
      elsif after.blank?
        cached = cached_result
        return { data: cached, has_more: false, next_after: nil, total_count: cached.size } if cached

        baseline = Rails.cache.read(baseline_key)
        if baseline.present?
          result = incremental_drain(baseline)
          publish(result)
          Rails.cache.delete(buffer_key(stream_id))
          return { data: result, has_more: false, next_after: nil, total_count: result.size }
        end
      end

      raw = page(after: after, limit: limit)
      data = raw["data"] || []
      has_more = data.any? && raw["has_more"]

      buffered = (Rails.cache.read(buffer_key(stream_id)) || []) + data

      if has_more
        # A reload's buffer has to outlive the gaps between its pages by enough
        # that the fallback job can still pick the walk up where it stopped, so
        # it's kept for as long as the claim itself rather than the couple of
        # minutes an ordinary stream needs.
        Rails.cache.write(buffer_key(stream_id), buffered, expires_in: reload ? FULL_RELOAD_LOCK_TTL : 2.minutes)
      else
        publish(buffered)
        Rails.cache.delete(buffer_key(stream_id))
        release_full_reload! if reload
      end

      { data: data, has_more: has_more, next_after: has_more ? data.last["id"] : nil, total_count: raw["total_count"] }
    end

    private

    # Re-stamps the claim so #resume_full_reload! can see the stream is still
    # being driven. Rewritten rather than merged: the claim belongs to this
    # stream (the caller checked #full_reload_stream?), and the only field on it
    # that moves is the heartbeat.
    def touch_full_reload!(stream_id)
      Rails.cache.write(
        full_reload_lock_key,
        { stream_id: stream_id, touched_at: Time.now },
        expires_in: FULL_RELOAD_LOCK_TTL
      )
    end

    def buffer_key(stream_id) = "#{cache_key}:buffer:#{stream_id}"

    def cache_key = "hcb:org:#{@organization_id}:transactions:v2:#{filters_cache_key}"

    def by_id_key = "#{cache_key}:by_id"

    def derived_key = "#{cache_key}:derived"

    def presented_key = "#{cache_key}:presented"

    def ledger_order_key = "#{cache_key}:ledger_order"

    def baseline_key = "#{cache_key}:baseline"

    # v2 held a {at:, count:} stamp rather than the bare Time v1 held, so
    # #sync_state can report how much is cached without deserializing the whole
    # transaction array on every poll; v3 adds the per-drain :token every
    # Hcb::LocalCache entry is validated against. Renaming (rather than reading
    # both shapes) means an already-warm older cache is simply treated as
    # unstamped, which #maybe_refresh_ahead reads as due-for-a-refresh and
    # LocalCache reads as "don't memo this" -- so the first request after a
    # deploy re-stamps it and the transition heals itself.
    def fetched_at_key = "#{cache_key}:fetched:v3"

    def refresh_lock_key = "#{cache_key}:refreshing"

    def full_reload_lock_key = "#{cache_key}:full_reloading"

    def filters_cache_key
      @filters.to_a.sort_by(&:first).to_h.to_json
    end

    def by_id_cache = memoized(by_id_key) { Rails.cache.read(by_id_key) }

    # The drained history as it currently stands, or nil. Deliberately *not*
    # memoized on the instance, and it re-reads the stamp: this is the read
    # that has to notice the primary cache expiring (the stamp expires with
    # it, so an expired drain reads as unversioned and no local copy can stand
    # in for it) and the caller's next move is to redrain. Each flow that
    # needs it calls it once, so there's nothing here worth memoizing anyway.
    def cached_result
      token = version_token(reload: true)
      LocalCache.read(cache_key, token) || LocalCache.write(cache_key, token, Rails.cache.read(cache_key))
    end

    # The freshness stamp. Read once per instance unless a caller asks for it
    # again: everything #memoized fronts is validated against the token in
    # here, so a request that touches four drain caches pays one small read
    # instead of four large ones.
    def stamp(reload: false)
      @stamp = Rails.cache.read(fetched_at_key) if reload || !defined?(@stamp)
      @stamp
    end

    def version_token(reload: false) = stamp(reload: reload) && stamp[:token]

    # Reads through Hcb::LocalCache (see there for why), with a per-instance
    # memo in front of it so a caller in a loop doesn't even pay the token
    # comparison -- and so the per-instance memoization these keys have always
    # had survives when the local cache is disabled (no stamp yet, or a store
    # that drops writes).
    def memoized(key)
      @memo ||= {}
      return @memo[key] if @memo.key?(key)

      hit = LocalCache.read(key, version_token)
      return @memo[key] = hit unless hit.nil?

      value = yield
      # The block may itself have drained and published, which advances the
      # token -- store under the new one, or the entry could never be read.
      LocalCache.write(key, version_token, value)
      @memo[key] = value
    end

    # Every "we have a new authoritative copy of the org's transactions" write
    # in one place: the primary cache, the incremental-drain baseline, the
    # freshness stamp, and the derived side caches. Anything that produces a
    # full result -- a drain, a stream's last page, a #sync_head! splice --
    # goes through here, so none of them can update one and forget another.
    def publish(result)
      # Stamped before anything else is written, so the token every reader
      # validates its local copy against is the one belonging to *this* drain
      # -- including this instance's own memo, which the stamp assignment
      # below invalidates along with it.
      new_stamp = { at: Time.now, count: result.size, token: SecureRandom.hex(8) }
      @stamp = new_stamp
      @memo = {}

      Rails.cache.write(cache_key, result, expires_in: TTL)
      Rails.cache.write(baseline_key, result, expires_in: BASELINE_TTL)
      Rails.cache.write(fetched_at_key, new_stamp, expires_in: TTL)
      # Seeded rather than left for the next read to fault in: the process that
      # just drained (a warming job, or the request that missed) already has
      # the objects in hand, so this is free where re-reading them isn't.
      LocalCache.write(cache_key, new_stamp[:token], result)
      write_side_caches(result)
      result
    end

    # Computed once per drain (see #publish), not per request -- this is the
    # O(n) walk that used to happen fresh inside OrganizationLedger on every
    # single request that needed a lookup or cutoff classification.
    def write_side_caches(result)
      token = version_token

      by_id = result.index_by { |t| t["id"] }
      Rails.cache.write(by_id_key, by_id, expires_in: TTL)
      LocalCache.write(by_id_key, token, by_id)

      write_presentation_caches(result, token)

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

      # amounts_cents is here rather than left to a #find on the by-id index
      # because the write paths only ever want a leg's amount, and #find has to
      # deserialize the whole org's raw transaction JSON (megabytes) to answer
      # -- see OrganizationLedger#write_legs_by_id. Keyed over the *whole* drain
      # rather than the declined-excluded ordering above, so it answers for
      # exactly the same set of ids #find does and the two can't disagree.
      amounts_cents = result.to_h { |t| [ t["id"], t["amount_cents"] || 0 ] }

      derived = {
        position_by_id: position_by_id,
        ids: ids,
        dates: dates,
        amounts_cents: amounts_cents,
        balances_cents: balances_cents
      }
      Rails.cache.write(derived_key, derived, expires_in: TTL)
      LocalCache.write(derived_key, token, derived)
    end

    # The response-shaped half of the side caches: every transaction rendered
    # to the JSON the frontend reads, plus the order and per-row arithmetic
    # inputs the full-history ledger view needs to lay those fragments out.
    #
    # Presenting the whole drain here rather than per request is the point --
    # a warm /api/transactions or /api/ledger then costs a string join, not a
    # presenter allocation and a JSON generation per row. Storing the
    # fragments as strings (rather than hashes) is deliberate too: the strings
    # are what the response wants, and a hash of strings is markedly cheaper to
    # Marshal back in than the same data as nested hashes.
    def write_presentation_caches(result, token)
      presenters = result.map { |t| TransactionPresenter.new(t) }

      presented = presenters.to_h { |p| [ p.id, p.as_json.to_json ] }
      Rails.cache.write(presented_key, presented, expires_in: TTL)
      LocalCache.write(presented_key, token, presented)

      # Sorted exactly as Api::LedgerController#index sorted it inline: by the
      # date the row displays (when it was sent), id breaking ties so the order
      # is stable across drains.
      ordered = presenters.sort_by { |p| [ p.date.to_s, p.id.to_s ] }
      ledger_order = {
        ids: ordered.map(&:id),
        amounts_cents: ordered.map(&:amount_cents),
        declined: ordered.map(&:declined?)
      }
      Rails.cache.write(ledger_order_key, ledger_order, expires_in: TTL)
      LocalCache.write(ledger_order_key, token, ledger_order)
    end

    # No-ops unless @client can identify who's asking (a real, logged-in
    # user's Hcb::Client) -- there's no local record of which users belong to
    # which HCB organization, so warming can only piggyback on real traffic.
    # The refresh_lock_key write is a compare-and-set: only the first request
    # to observe a due-for-a-check cache enqueues the job; everyone else
    # within the interval just gets served the current cache.
    def maybe_refresh_ahead
      return unless @client.respond_to?(:user_id) && @client.user_id

      return if stamp && Time.now - stamp[:at] < BACKGROUND_REFRESH_INTERVAL
      return unless Rails.cache.write(refresh_lock_key, true, expires_in: BACKGROUND_REFRESH_INTERVAL, unless_exist: true)

      WarmOrganizationTransactionsJob.perform_later(@client.user_id, @organization_id, filters: @filters)
    end

    # Shared by #all's cache-miss path and #refresh!: incrementally redrains
    # against whatever baseline we have, falling back to a full #drain when
    # there isn't one. Pure computation -- callers #publish the result, which is
    # what re-saves it as the next redrain's baseline.
    def redrain
      incremental_drain(Rails.cache.read(baseline_key))
    end

    # `after` lets a caller pick the walk up mid-history rather than from the
    # newest transaction -- see #resume_full_reload!, which continues from the
    # last page an abandoned reload stream had already fetched.
    def drain(after: nil)
      results = []

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
      first = page(limit: PAGE_SIZE)

      parallel_incremental_drain(previous, first) ||
        serial_incremental_drain(previous, previous_index, first)
    end

    # The overlap window in one concurrent burst instead of one round trip per
    # page, using the previous drain as a source of cursors.
    #
    # The first page still has to come back before anything else can be asked
    # for, because it's what says how far HCB's list has shifted since the last
    # drain: everything new sits at the head, so finding where the previous
    # drain's newest transaction turns up in that page gives the offset. Once
    # that's known, every remaining page of the window has a cursor we can name
    # from the baseline, so they all go out together -- two round trips for the
    # whole redrain rather than SAFETY_OVERLAP / PAGE_SIZE of them.
    #
    # Returns nil, meaning "fall back to walking it serially", whenever the
    # pages that come back don't tile the baseline exactly: more than one page
    # of new activity (so the offset can't be read off the first page), a
    # transaction gone from the middle of the window, a cursor HCB no longer
    # recognizes. Those are the cases where guessing cursors from a stale
    # baseline could splice a gap into the result, and a gap in the drain is a
    # wrong running balance -- so the cheap path only ever produces a result it
    # can prove is contiguous, and hands back nil otherwise.
    #
    # In-place changes *are* picked up: an id that stays put but comes back
    # declined, or with a corrected amount, still tiles, and it's the freshly
    # fetched copy that lands in the result. Catching exactly that is what
    # SAFETY_OVERLAP is for.
    def parallel_incremental_drain(previous, first)
      return nil if MAX_CONCURRENT_PAGES <= 1

      head = first["data"] || []
      return nil if head.empty? || !first["has_more"]

      # How many transactions have landed since the drain we're building on:
      # where that drain's newest transaction shows up in HCB's newest page.
      new_count = head.index { |t| t["id"] == previous.first["id"] }
      return nil if new_count.nil?

      # head is authoritative for its whole span, so the rest of it should be
      # the baseline's own head, transaction for transaction. If it isn't, the
      # baseline has diverged in a way cursors picked from it can't be trusted.
      overlap = head[new_count..]
      return nil unless overlap.each_with_index.all? { |t, i| previous[i] && previous[i]["id"] == t["id"] }

      # Baseline position the first page consumed through, and the cursors for
      # the pages that carry the rest of the overlap window. Each is the id
      # immediately before the page it fetches, which is what `after` means.
      consumed_through = overlap.size - 1
      cursor_positions = (consumed_through...(SAFETY_OVERLAP - new_count - 1)).step(PAGE_SIZE).to_a
      return nil if cursor_positions.any? { |position| previous[position].nil? }
      return head + (previous[(consumed_through + 1)..] || []) if cursor_positions.empty?

      pages = parallel_pages(cursor_positions.map { |position| previous[position]["id"] })
      return nil if pages.nil?

      # Same tiling check as above, now for each fetched page against the span
      # of the baseline its cursor should have landed it on.
      fetched = []
      cursor_positions.zip(pages).each do |position, data|
        return nil if data.empty?
        return nil unless data.each_with_index.all? { |t, i| previous[position + 1 + i] && previous[position + 1 + i]["id"] == t["id"] }

        fetched.concat(data)
        consumed_through = position + data.size
      end

      head + fetched + (previous[(consumed_through + 1)..] || [])
    end

    # The given cursors' pages, fetched concurrently and returned in the order
    # asked for. nil if any of them failed -- the caller's answer to that is to
    # walk the window serially instead, which is also the right answer to a
    # cursor HCB rejects (a 400 for an `after` it can't find).
    def parallel_pages(cursors)
      @client.warm_token! if @client.respond_to?(:warm_token!)

      cursors.each_slice(MAX_CONCURRENT_PAGES).flat_map { |batch|
        batch.map { |cursor|
          Thread.new do
            Rails.application.executor.wrap do
              page(after: cursor, limit: PAGE_SIZE)["data"] || []
            end
          end
        }.map(&:value)
      }
    rescue Hcb::TokenExpiredError
      raise
    rescue StandardError
      nil
    end

    # Pages the overlap window one cursor at a time, taking the first page as
    # already fetched. The fallback for everything #parallel_incremental_drain
    # declines to answer, and the only path that runs when there's no usable
    # baseline to pick cursors from.
    def serial_incremental_drain(previous, previous_index, first)
      fresh = []
      current = first

      loop do
        data = current["data"] || []
        break if data.empty?

        fresh.concat(data)

        if fresh.size >= SAFETY_OVERLAP
          rejoin_at = previous_index[fresh.last["id"]]
          return fresh + previous[(rejoin_at + 1)..] if rejoin_at
        end

        break unless current["has_more"]

        current = page(after: data.last["id"], limit: PAGE_SIZE)
      end

      fresh
    end
  end
end
