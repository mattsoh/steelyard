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
  #
  # Every walk of HCB runs as a *task*: one per organization at a time, claimed
  # under a compare-and-set lock, normally run by WarmOrganizationTransactionsJob
  # rather than by whichever browser asked. The task records its progress
  # (DrainProgress) and what it is doing (ActivityLog) in the cache as it goes,
  # and keeps each page it fetches where any viewer can read it (#task_pages).
  # So a tab that opens the organization mid-walk -- or the tab that asked,
  # after being closed and reopened -- sees the same walk, the same history of
  # it, and the same rows so far, with nothing depending on any one browser
  # staying open.
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

    # How long a claimed task blocks another one from being started --
    # comfortably longer than a full-history drain takes, since the point is to
    # stop a second one being queued *while the first is still running*. The
    # claim is released as soon as the task lands or fails, so this only matters
    # if whoever held it died without ever finishing -- and a dead task is
    # noticed long before this through DrainProgress::STALE_AFTER.
    TASK_CLAIM_TTL = 15.minutes

    # The pages a buffered task has fetched so far are kept well past the claim,
    # so a task that takes over from a dead one -- or a retry after a failure --
    # can carry on from them. Deleted outright once the walk publishes.
    TASK_PAGE_TTL = 1.hour

    # After a task fails, how long the read paths decline to start another one
    # on their own. Every open tab polls while it waits on a load, and without
    # this each poll would restart the task the moment it failed, which against
    # an HCB that is down is a tight loop of failures against the shared rate
    # limit. An explicit retry (#ensure_loaded! with force: true) ignores it.
    FAILURE_BACKOFF = ENV.fetch("HCB_TASK_FAILURE_BACKOFF", 60).to_i.seconds

    # What a task claim can be for -- the same kinds DrainProgress reports.
    TASK_KINDS = %i[cold incremental reload].freeze

    # What #refresh_one! hands back: the same transaction as the cache had it
    # and as HCB has it now, for callers that want to report what changed.
    RefreshedTransaction = Struct.new(:previous, :current, keyword_init: true)

    # Raised inside a task whose claim has been taken by another task (one that
    # judged this one dead). Carrying on would walk the same history a second
    # time and publish over the new owner, so the task stops where it is.
    class Superseded < StandardError; end

    def initialize(client, organization_id, filters: {})
      @client = client
      @organization_id = organization_id
      @filters = filters.compact.deep_stringify_keys
    end

    # How far along whatever task is currently running has got. Advisory and
    # cache-only -- see Hcb::DrainProgress.
    def progress = @progress ||= DrainProgress.new(cache_key)

    # What has been happening to this organization's data, for every viewer to
    # read -- see Hcb::ActivityLog.
    def activity = @activity ||= ActivityLog.new(cache_key)

    def page(after: nil, limit: PAGE_SIZE)
      @client.transactions(@organization_id, after: after, limit: limit, filters: @filters)
    end

    def all(bypass_cache: false)
      return drain if bypass_cache

      result = cached_result
      unless result
        # A live task is already rebuilding this. Draining here would be a
        # second full walk of the same history against the rate limit the
        # claim exists to protect -- so this answers "nothing yet" and lets the
        # caller say a load is running (see #sync_state, and #draining? on
        # OrganizationLedger).
        return [] if drain_running?

        # Nothing cached and nobody working on it. The web endpoints never get
        # here (they call #ensure_loaded! first and answer "loading" instead of
        # blocking), so this is a caller with no way to wait -- the public API,
        # the MCP server, a match being saved -- and it drains on its own
        # thread, as a task like any other so a browser that opens the
        # organization meanwhile sees the walk rather than starting one.
        #
        # A stalled claim is taken over here too, finishing the walk it left
        # behind rather than waiting for it to expire or starting over.
        task_id = start_task!(kind: natural_kind, source: "inline", requested_by: "a direct request")
        return [] if task_id.nil?

        result = run_task!(task_id)
        # Taken over mid-walk by another task; whatever it has published since
        # is the answer, and nothing if it hasn't yet.
        return cached_result || [] unless result.is_a?(Array)
      end

      maybe_refresh_ahead
      result
    end

    # The drained history as it currently stands, or nil when there is nothing
    # warm to answer from -- never drains. For callers that want to know rather
    # than wait (StreamedTransactionPages, which answers a cold organization
    # with the task building it instead).
    def cached_all = cached_result

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

    # Redrains on the calling thread and overwrites the cache, regardless of
    # what's currently in it -- the write side of cache warming, for a caller
    # that wants the result now. Run as a task so viewers see it; if a live
    # task already owns the organization, that task's result is what this
    # returns (nothing yet, if it hasn't landed).
    def refresh!
      task_id = start_task!(kind: natural_kind, source: "inline", requested_by: "a direct refresh")
      return cached_result || [] if task_id.nil?

      result = run_task!(task_id)
      result.is_a?(Array) ? result : (cached_result || [])
    end

    # Full-history redrain that ignores the baseline entirely: every page is
    # re-fetched from HCB rather than paging forward only to a rejoin point. So
    # it costs one HCB request per PAGE_SIZE transactions of *total* org
    # history, where #refresh! costs one per PAGE_SIZE of recent activity --
    # which is why the UI warns before asking for it. It exists for the case an
    # incremental drain can't heal on its own: a transaction that changed
    # further back than SAFETY_OVERLAP reaches, so every redrain keeps splicing
    # the stale copy back on.
    def reload!(requested_by: "a direct reload")
      task_id = start_task!(kind: :reload, source: "inline", requested_by: requested_by, resume: false)
      return cached_result || [] if task_id.nil?

      purge!
      result = run_task!(task_id)
      result.is_a?(Array) ? result : (cached_result || [])
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
    def refresh_one!(id, requested_by: nil)
      current = cached_result || all
      index = current.index { |t| t["id"] == id }
      return nil if index.nil?

      fresh = @client.transaction(id)
      return RefreshedTransaction.new(previous: current[index], current: current[index]) if fresh.blank? || fresh["id"] != id

      previous = current[index]
      updated = current.dup
      updated[index] = fresh
      publish(updated, finish_progress: false)
      # OrganizationLedger keeps its own long-lived per-id copy for ids that
      # aren't in the drain; drop it so it can't shadow what we just re-fetched.
      Rails.cache.delete(OrganizationLedger.single_transaction_cache_key(@organization_id, id))

      changed = previous != fresh
      activity.append(
        "#{requested_by || 'someone'} re-checked #{id} against HCB — #{changed ? 'HCB has restated it, cache updated' : 'unchanged'}",
        kind: changed ? "warn" : "hcb"
      )

      RefreshedTransaction.new(previous: previous, current: fresh)
    end

    # ------------------------------------------------------------------------
    # Tasks
    # ------------------------------------------------------------------------

    # Compare-and-set claim on the one walk this organization may have running,
    # so two people opening it at once -- or one person with two tabs open, or
    # a tab and the background refresh -- can't spend the shared HCB rate limit
    # twice on the same history. Everyone but the claimant watches the one
    # task's progress, which is the same result for less money.
    #
    # `kind` decides what the task does (see DrainProgress::KINDS); `resume`
    # whether a task that takes over a stalled one may carry on from the pages
    # it left behind (anything but an explicit reload, which exists precisely
    # to re-read them).
    #
    # Returns the new task's id, or nil when a live task already holds the
    # organization -- in which case the caller attaches to that one.
    def start_task!(kind:, requested_by:, source: "background", resume: true)
      raise ArgumentError, "unknown task kind #{kind}" unless TASK_KINDS.include?(kind.to_sym)

      task_id = SecureRandom.uuid

      # Whatever a previous attempt left behind -- one that died, or one that
      # failed and is now being retried -- is carried on from rather than
      # re-fetched, where its pages are still around. That is what an
      # interrupted walk should cost: nothing.
      previous = progress.read
      resume_pages =
        if resume && previous && previous[:phase] != "done" && previous[:kind].in?(DrainProgress::BUFFERED_KINDS)
          buffered_page_count(previous[:pages_done].to_i)
        else
          0
        end

      claim = { task_id: task_id, kind: kind.to_sym, resume_pages: resume_pages }
      # Remembered on the instance as well as in the store, so a task started
      # and run on the same thread (#all draining inline) still knows what it
      # is on a store that keeps nothing -- the :null_store the test
      # environment runs on.
      (@started_tasks ||= {})[task_id] = claim
      unless Rails.cache.write(task_claim_key, claim, expires_in: TASK_CLAIM_TTL, unless_exist: true)
        current = task_claim
        return nil if current && !stale_task?(current)

        # Nobody is advancing the task that holds the claim: the job never got
        # picked up, or the worker running it died. Take it over rather than
        # waiting for the claim to expire.
        Rails.cache.write(task_claim_key, claim, expires_in: TASK_CLAIM_TTL)
        activity.append("the previous load stopped responding — taking it over", kind: "warn", task_id: task_id)
      end
      if resume_pages.positive?
        activity.append("#{resume_pages} page#{'s' unless resume_pages == 1} from the previous attempt are still here — picking up from page #{resume_pages + 1}", task_id: task_id)
      end

      progress.start!(
        task_id: task_id, kind: kind, source: source, requested_by: requested_by,
        total_count: kind.to_sym == :incremental ? Rails.cache.read(baseline_key)&.size : nil
      )
      activity.append(task_started_line(kind, requested_by, source), kind: kind.to_sym == :reload ? "warn" : "info", task_id: task_id)
      task_id
    end

    # Makes sure this organization is either warm or being loaded, and says
    # which: nil when the caches are warm, otherwise the progress record of the
    # task building them -- one already running, or one started here and handed
    # to WarmOrganizationTransactionsJob.
    #
    # This is what the web endpoints call instead of #all, so a cold
    # organization is answered with "loading, here's the task" in milliseconds
    # rather than holding a request open for a multi-minute walk. Which browser
    # asked first no longer matters: the task is the organization's, and every
    # tab polls the same one.
    #
    # `force` is the explicit retry after a failure; without it a recent failure
    # is left alone for FAILURE_BACKOFF rather than restarted by every poll.
    def ensure_loaded!(requested_by:, user_id: @client.user_id, force: false)
      return nil if cached_result && !full_reload_running?

      claim = task_claim
      return progress.read if claim && !stale_task?(claim)

      last = progress.read
      if !force && last && last[:phase] == "failed" && Time.now.to_f - last[:finished_at].to_f < FAILURE_BACKOFF
        return last
      end

      task_id = start_task!(kind: natural_kind, requested_by: requested_by)
      return progress.read if task_id.nil?

      WarmOrganizationTransactionsJob.perform_later(user_id, @organization_id, filters: @filters, task_id: task_id)
      progress.read
    end

    # Runs the task `task_id` names, on this thread, to completion: the walk the
    # claim's kind calls for, published at the end. The one routine behind
    # every drain -- WarmOrganizationTransactionsJob calls it, and so does #all
    # when it has to drain inline -- so there is one place that knows how to
    # fetch, buffer, record, publish and release.
    #
    # Returns the published result, or :superseded if the claim was no longer
    # this task's to run (another task judged it dead and took over).
    def run_task!(task_id)
      claim = task_claim
      # A claim naming another task means this one was judged dead and replaced.
      # No claim at all is not that: it is a store that doesn't persist, or a
      # claim released out from under a task nobody replaced -- neither a
      # reason to abandon work that was asked for.
      return :superseded if claim && claim[:task_id] != task_id

      claim ||= @started_tasks&.dig(task_id)
      return :superseded unless claim

      kind = claim[:kind]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        result =
          case kind
          when :incremental
            baseline = Rails.cache.read(baseline_key)
            if baseline.present?
              incremental_drain(baseline, task_id: task_id)
            else
              # Nothing to splice onto, so this is a cold walk in all but name
              # -- and the name matters, because it is what tells viewers there
              # are pages to render as it goes.
              progress.update!(kind: "cold")
              activity.append("no previous drain to build on — walking the full history", kind: "warn", task_id: task_id)
              drain(task_id: task_id, buffer: true)
            end
          else
            inherited = inherited_pages(claim[:resume_pages].to_i)
            if inherited.any?
              progress.advance!(pages_done: inherited.size, transactions_done: inherited.sum(&:size))
              activity.append("#{inherited.sum(&:size)} transactions from the previous attempt's #{inherited.size} pages, carrying on", task_id: task_id)
            end
            inherited.flatten + drain(
              after: inherited.last&.last&.dig("id"),
              pages_done: inherited.size,
              already_done: inherited.sum(&:size),
              task_id: task_id,
              buffer: true
            )
          end

        progress.phase!("publishing")
        activity.append("publishing #{result.size} transactions and rebuilding the derived caches…", task_id: task_id)
        publish(result)
        forget_task_pages

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        activity.append("done — #{result.size} transactions published in #{elapsed.round(1)}s", kind: "done", task_id: task_id)
        result
      rescue Superseded
        activity.append("stopped: another task took this load over", kind: "warn", task_id: task_id)
        :superseded
      rescue StandardError => e
        progress.fail!(e.message)
        activity.append("load failed: #{e.message.to_s.truncate(200)}", kind: "error", task_id: task_id)
        raise
      ensure
        # Released whatever happened, but only if it is still ours: a claim left
        # behind by a task that died would block the retry someone is about to
        # ask for for its whole TTL, and a claim that has moved on to another
        # task is that task's to release. The pages a failed walk fetched are
        # deliberately kept (until TASK_PAGE_TTL) for the retry to carry on from.
        current = task_claim
        release_task! if current && current[:task_id] == task_id
      end
    end

    # The raw transactions of the pages a buffered task has fetched so far,
    # after the `after_page`th -- what a viewer renders while the walk runs.
    # Empty for a task whose kind keeps no pages (an incremental splice), and
    # for a page count the record hasn't reached yet.
    def task_pages(after_page = 0)
      record = progress.read
      return [] unless record && record[:running] && record[:kind].in?(DrainProgress::BUFFERED_KINDS)

      ((after_page.to_i + 1)..record[:pages_done].to_i).flat_map { |n| Rails.cache.read(page_key(n)) || [] }
    end

    def task_claim
      claim = Rails.cache.read(task_claim_key)
      claim.is_a?(Hash) ? claim : nil
    end

    def release_task! = Rails.cache.delete(task_claim_key)

    # A claim nobody is advancing any more -- whoever holds it may be taken
    # over by the next task to want the organization.
    def stale_task?(claim = task_claim)
      return false unless claim

      !progress.live?
    end

    # A task really is running right now -- what a caller about to start its own
    # checks so it can attach to the one already there instead.
    def drain_running?
      claim = task_claim
      claim.present? && !stale_task?(claim)
    end

    # Deliberately reload-only. Every read path treats this as "there is no data
    # to serve, wait"; a cold task is the opposite case (nothing has been
    # purged, and whatever is cached is still correct), so answering true for
    # one would blank an organization that was merely loading for the first time.
    def full_reload_running?
      claim = task_claim
      claim.present? && claim[:kind] == :reload && !stale_task?(claim)
    end

    # Drops everything derived from the previous drain, so a full reload starts
    # from nothing rather than on top of what it's replacing.
    #
    # The drain a reload performs was always fresh -- it raw-pages HCB and never
    # consults the baseline -- but that isn't the same as starting clean, and the
    # difference is where the stale copies were surviving:
    #
    #   * the baseline. Left in place, the *next* ordinary redrain splices the
    #     old rows straight back on -- including whatever wrong value someone
    #     reached for the full reload to be rid of. A reload that leaves this
    #     behind can be undone by the request after it.
    #   * the side caches (by-id, presented, ledger order, derived). Keyed to
    #     the old drain's token so nothing reads them once a new one publishes,
    #     but until then they're what every warm request is answered from.
    #   * the per-id transaction cache, which outlives the drain by a day and
    #     can shadow a transaction the reload just re-fetched. Orphaned by
    #     generation rather than deleted -- see
    #     OrganizationLedger#bump_single_transaction_generation!.
    #
    # Dropping the stamp is also what stops the drain caches being served from
    # any process's Hcb::LocalCache: entries there are only readable on an exact
    # version-token match, and after this there is no current token to match.
    #
    # The task record and the activity log are deliberately left alone: the
    # reload is itself a task, and wiping its record would blank the progress
    # every viewer is about to watch.
    def purge!
      [ cache_key, by_id_key, derived_key, presented_key, ledger_order_key, baseline_key, fetched_at_key ].each do |key|
        Rails.cache.delete(key)
        LocalCache.forget(key)
      end
      OrganizationLedger.bump_single_transaction_generation!(@organization_id)

      # This instance's own memo of all of the above, which would otherwise go
      # on answering from the drain that was just dropped.
      @stamp = nil
      @memo = {}
      nil
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
    #              redrain (a background task)
    #   :draining  -- nothing cached yet, but a task is already building it; the
    #              caller waits for that rather than starting a second one
    #   :reloading -- a full reload owns the organization; same answer, said
    #              differently
    def sync_head!(requested_by: nil)
      who = requested_by || "someone"

      # A full reload is a stronger version of what this would ask for, already
      # in flight. Answering :deep would have the caller queue an incremental
      # redrain on top of it -- which spends an HCB request to splice the very
      # baseline the reload dropped, and publishes a fetched_at that the
      # reloading tab reads as its own drain having landed.
      return :reloading if full_reload_running?

      # A task is already walking this organization -- a cold load, or the
      # background refresh -- which covers everything a peek would find. Waiting
      # for it is the answer, not a splice published beside it (whose progress
      # record would overwrite the task's and make a live walk look dead).
      # Distinct from :reloading because the caller words the two differently.
      return :draining if drain_running?

      cached = cached_result
      return :deep if cached.blank?

      # Deliberately no progress record for the peek itself. It is a single
      # request, nothing else needs to watch it, and stamping one here would
      # overwrite the finished record of the drain before it -- so a poller
      # arriving mid-peek would see the last completed drain replaced by a walk
      # that, in the overwhelmingly common :fresh case, never happens.
      head = page(limit: PEEK_SIZE)["data"] || []
      if head.empty?
        activity.append("#{who} checked HCB for new activity — nothing there", kind: "hcb")
        return :fresh
      end

      # Where HCB's newest page rejoins the cache. Both lists are newest-first,
      # so head.last is the *oldest* transaction in the peek.
      rejoin_at = cached.index { |t| t["id"] == head.last["id"] }

      # Not in the cache at all: either more than PEEK_SIZE transactions have
      # landed since the last drain, or the cache diverges in a way one page
      # can't explain. Needs a real redrain to splice safely.
      if rejoin_at.nil?
        activity.append("#{who} checked HCB for new activity — more changed than one page explains, a full redrain is needed", kind: "warn")
        return :deep
      end

      # If nothing were new, the peek would line up exactly with the head of the
      # cache, so its oldest transaction would sit at index head.size - 1.
      # Anything shallower than that is new transactions pushing it down; a
      # *deeper* rejoin means transactions the cache has are gone from HCB's
      # newest page, which one page can't explain either.
      new_count = head.size - 1 - rejoin_at
      if new_count.negative?
        activity.append("#{who} checked HCB for new activity — transactions have disappeared from HCB's newest page, a full redrain is needed", kind: "warn")
        return :deep
      end
      if new_count.zero? && head == cached[0, head.size]
        activity.append("#{who} checked HCB for new activity — already up to date", kind: "hcb")
        return :fresh
      end

      # Past here something really did change, so there is work worth showing --
      # and #publish below will close the record out as done.
      progress.start!(kind: "incremental", source: "inline", requested_by: requested_by, total_count: cached.size)
      progress.advance!(pages_done: 1, transactions_done: head.size, phase: "splicing")

      # head is authoritative for its whole span, not just for the new rows, so
      # this also picks up in-place changes to already-seen transactions inside
      # the peek (one going declined, an amount corrected) -- the same thing
      # SAFETY_OVERLAP exists to catch on a full redrain.
      publish(head + cached[(rejoin_at + 1)..])
      activity.append(
        "#{who} checked HCB for new activity — #{new_count.positive? ? "#{new_count} new transaction#{'s' unless new_count == 1}" : 'recent transactions restated'}, spliced into the cache",
        kind: "done"
      )
      :synced
    end

    # Names the drain every cache entry currently belongs to. A browser that
    # kept rows from this same token can render them without asking for a single
    # page; any new drain anywhere changes it, so a stale copy can never be
    # mistaken for a current one. Same token Hcb::LocalCache validates against.
    def drain_token = version_token(reload: true)

    # Cache-only snapshot of how current the drain is, so a client can poll a
    # background task's progress without spending an HCB request per poll.
    # fetched_at advances exactly when a new result is published, which is the
    # signal a caller waiting on #sync_head!'s :deep case watches for.
    #
    # `log_after` is the last activity seq the caller has rendered; only lines
    # after it are included, so a poll carries what is new rather than the
    # whole history each time.
    def sync_state(log_after: nil)
      claim = task_claim
      live = claim.present? && !stale_task?(claim)
      {
        fetched_at: stamp && stamp[:at].to_f,
        count: stamp && stamp[:count],
        # The drain the current caches belong to. A client that cached rows
        # against this token can tell in one small request whether its copy is
        # still the current one -- which is the difference between re-reading
        # the whole organization and rendering it instantly. See
        # syncStatus()/readCachedRows in streaming.js.
        token: version_token,
        reloading: live && claim[:kind] == :reload,
        # A task is live, so a second tab can attach to it rather than starting
        # its own against the shared rate limit.
        draining: live,
        drain_kind: live ? claim[:kind] : nil,
        progress: progress.read,
        log: activity.read(after: log_after)
      }
    end

    # Which walk a load that isn't an explicit reload should be: a splice onto
    # the baseline where there is one, the full history where there isn't.
    def natural_kind = Rails.cache.read(baseline_key).present? ? :incremental : :cold

    private

    def task_started_line(kind, requested_by, source)
      who = requested_by.presence || "something"
      what =
        case kind.to_sym
        when :reload      then "started a full reload — re-reading the entire history from HCB; the cached copy has been cleared"
        when :incremental then "started checking HCB for recent activity to splice onto the previous drain"
        else                   "started loading this organization's full history from HCB for the first time"
        end
      "#{who} #{what}#{source.to_s == 'background' ? ' (background task)' : ''}"
    end

    # How many of the first `pages_done` buffered pages are actually still
    # there, as a contiguous run from page 1 -- a gap means the pages after it
    # can't be trusted to join up.
    def buffered_page_count(pages_done)
      (1..pages_done).take_while { |n| Rails.cache.read(page_key(n)).present? }.size
    end

    def inherited_pages(count)
      (1..count).map { |n| Rails.cache.read(page_key(n)) || [] }
    end

    def forget_task_pages
      pages = progress.read&.dig(:pages_done).to_i
      (1..pages).each { |n| Rails.cache.delete(page_key(n)) }
    end

    # The walk's claim, re-read before each page: if it names another task, this
    # one has been judged dead and replaced, and must stop. While it is still
    # ours its TTL is pushed out again, so a walk longer than TASK_CLAIM_TTL
    # keeps its claim for as long as it keeps advancing.
    def check_claim!(task_id)
      return unless task_id

      claim = task_claim
      raise Superseded if claim && claim[:task_id] != task_id

      Rails.cache.write(task_claim_key, claim, expires_in: TASK_CLAIM_TTL) if claim
    end

    def page_key(n) = "#{cache_key}:task_page:#{n}"

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

    def task_claim_key = "#{cache_key}:task_claim"

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
    # full result -- a task, a #sync_head! splice -- goes through here, so none
    # of them can update one and forget another.
    #
    # `finish_progress: false` is for a write that isn't the end of a task (a
    # single transaction re-fetched in place), which must not close out the
    # record of one that may be running.
    def publish(result, finish_progress: true)
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
      # Last, so a watcher that sees "done" and immediately re-reads finds every
      # cache the result is served from already written.
      progress.finish!(count: result.size) if finish_progress
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

      # Declined never moved money; a pending *incoming* transaction hasn't
      # moved yet and doesn't count until it settles (see
      # TransactionPresenter#pending_incoming?, and HCB's own
      # Event#balance_v2_cents). Neither belongs in the running balance, the
      # cutoff options derived from it, or the matcher's working set.
      #
      # Deliberately not applied to the by-id index or amounts below: those have
      # to answer for every drained id, because a match leg on a transaction
      # that has since gone pending must still resolve. A leg that stopped
      # resolving is one Matches::Resync drops from its match, and a display
      # rule is no reason to do that.
      ordered = result.reject { |t| t["declined"] || TransactionPresenter.pending_incoming?(t) }.reverse
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
      #
      # Pending incoming transactions are left out of the order (and so off the
      # ledger) but stay in `presented` above, which still has to answer for
      # every drained id -- a match leg pointing at one is rendered from there.
      ordered = presenters.reject(&:pending_incoming?).sort_by { |p| [ p.date.to_s, p.id.to_s ] }
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
    #
    # The job claims the task itself (there is no browser waiting on an id), so
    # a refresh that finds another task running simply does nothing.
    def maybe_refresh_ahead
      return unless @client.respond_to?(:user_id) && @client.user_id
      # Same reasoning as #sync_head!'s :reloading -- and more pressing here,
      # because a purged cache reads as maximally stale and would otherwise
      # queue a background redrain on every single request for the duration of
      # the reload. Any task counts, not just a reload: queueing a redrain
      # behind an organization's first cold drain buys a second copy of the
      # same history out of the rate limit the whole userbase shares.
      return if drain_running?

      return if stamp && Time.now - stamp[:at] < BACKGROUND_REFRESH_INTERVAL
      return unless Rails.cache.write(refresh_lock_key, true, expires_in: BACKGROUND_REFRESH_INTERVAL, unless_exist: true)

      WarmOrganizationTransactionsJob.perform_later(@client.user_id, @organization_id, filters: @filters)
    end

    # The full history, one page at a time from `after` (nil for the newest).
    # `pages_done`/`already_done` are what a task that took over from a dead one
    # inherited, so the counts a watcher sees carry on from where it stopped
    # rather than restarting at zero -- and so buffered pages are numbered on
    # from the ones already there.
    #
    # With `buffer: true` every page is kept under its number (see #task_pages)
    # for viewers to render as the walk runs, and for a successor task to resume
    # from if this one dies. `task_id` makes each page re-check the claim first.
    def drain(after: nil, pages_done: 0, already_done: 0, task_id: nil, buffer: false)
      results = []

      loop do
        check_claim!(task_id)

        before = hcb_stats
        page = self.page(after: after, limit: PAGE_SIZE)
        data = page["data"] || []
        results.concat(data)
        pages_done += 1

        Rails.cache.write(page_key(pages_done), data, expires_in: TASK_PAGE_TTL) if buffer

        progress.advance!(
          pages_done: pages_done,
          transactions_done: already_done + results.size,
          total_count: page["total_count"]
        )
        log_page(task_id, pages_done, data.size, already_done + results.size, page["total_count"], before)

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
    def incremental_drain(previous, task_id: nil)
      return drain(task_id: task_id) if previous.blank?

      previous_index = previous.each_with_index.to_h { |t, i| [ t["id"], i ] }
      progress.advance!(pages_done: 0, transactions_done: 0, total_count: previous.size)
      check_claim!(task_id)
      before = hcb_stats
      first = page(limit: PAGE_SIZE)
      progress.advance!(pages_done: 1, transactions_done: (first["data"] || []).size, total_count: first["total_count"])
      log_page(task_id, 1, (first["data"] || []).size, (first["data"] || []).size, first["total_count"], before)

      result = parallel_incremental_drain(previous, first, task_id: task_id)
      if result
        activity.append("recent window re-fetched in parallel and spliced onto the #{previous.size} previously drained transactions", task_id: task_id)
        return result
      end

      activity.append("the recent window doesn't line up with the previous drain — walking it page by page instead", kind: "warn", task_id: task_id)
      serial_incremental_drain(previous, previous_index, first, task_id: task_id)
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
    def parallel_incremental_drain(previous, first, task_id: nil)
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

      check_claim!(task_id)
      activity.append("#{new_count} new since the last drain — re-fetching the #{SAFETY_OVERLAP}-transaction safety window in #{cursor_positions.size} parallel pages", task_id: task_id)
      pages = parallel_pages(cursor_positions.map { |position| previous[position]["id"] })
      return nil if pages.nil?

      progress.advance!(
        pages_done: 1 + pages.size,
        transactions_done: head.size + pages.sum(&:size),
        phase: "splicing"
      )

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
    def serial_incremental_drain(previous, previous_index, first, task_id: nil)
      fresh = []
      current = first
      pages = 1

      loop do
        data = current["data"] || []
        break if data.empty?

        fresh.concat(data)
        progress.advance!(pages_done: pages, transactions_done: fresh.size)

        if fresh.size >= SAFETY_OVERLAP
          rejoin_at = previous_index[fresh.last["id"]]
          if rejoin_at
            activity.append("rejoined the previous drain after #{fresh.size} transactions — splicing the remaining #{previous.size - rejoin_at - 1} on", task_id: task_id)
            return fresh + previous[(rejoin_at + 1)..]
          end
        end

        break unless current["has_more"]

        check_claim!(task_id)
        before = hcb_stats
        current = page(after: data.last["id"], limit: PAGE_SIZE)
        pages += 1
        log_page(task_id, pages, (current["data"] || []).size, fresh.size + (current["data"] || []).size, current["total_count"], before)
      end

      fresh
    end

    # What the client has spent on HCB so far, for per-page timings in the log.
    # Zero for a client that doesn't count (nothing in this app's own tests
    # does), which the log simply leaves out.
    def hcb_stats
      @client.respond_to?(:stats) ? @client.stats : nil
    end

    def log_page(task_id, number, size, so_far, total, before)
      after = hcb_stats
      timing =
        if before && after && after[:requests] > before[:requests]
          " — HCB #{(after[:ms] - before[:ms]).round}ms"
        else
          ""
        end
      total_note = total ? " of ~#{total}" : ""
      activity.append("page #{number}: #{size} transactions#{timing} — #{so_far}#{total_note} so far", kind: "hcb", task_id: task_id)
    end
  end
end
