module Hcb
  # The record of the organization's current (or most recent) load task: what
  # kind of walk it is, who asked for it, and how far it has got, in a form
  # anything can read without touching HCB.
  #
  # One task runs per organization at a time (see OrganizationTransactions
  # #start_task!), in a background job rather than in whichever browser tab
  # happened to open the organization first. This record is how every viewer
  # of that organization -- the tab that asked, a tab opened a minute later, a
  # tab that comes back after being closed -- sees the same walk: the task
  # stamps its progress here as it goes and Api::TransactionsController
  # #sync_status hands it straight back.
  #
  # Cache-backed and advisory. It is written on the same schedule as the pages
  # it describes, never read to make a decision about *data*, and losing it
  # costs a progress bar, not a drain. The one decision that does rest on it is
  # liveness: a record nobody has advanced for STALE_AFTER is how the next
  # requester knows the task behind it has died and may be taken over.
  class DrainProgress
    # Long enough to outlive the gap between two slow HCB pages many times over,
    # short enough that a record nobody is advancing any more disappears rather
    # than sitting there describing a drain that died.
    TTL = 15.minutes

    # A finished (or failed) task is kept for much longer than a running one,
    # so a tab opened afterwards can still say what the last load was and when
    # it landed -- the same reason the activity log outlives the drain.
    FINISHED_TTL = 1.day

    # No update in this long means whoever was writing it has gone -- a killed
    # worker, a job that never got picked up. Readers show it as stalled, and
    # the next request to need the organization takes the task over rather
    # than waiting on it (OrganizationTransactions#start_task!).
    STALE_AFTER = ENV.fetch("HCB_DRAIN_PROGRESS_STALE_AFTER", 75).to_i.seconds

    # What the task is doing right now. Only ever shown to a human -- nothing
    # branches on these except `done`/`failed` meaning "not running".
    #   starting   -- claimed, nothing fetched yet
    #   peeking    -- one page, asking whether anything is new (#sync_head!)
    #   draining   -- walking pages from HCB
    #   splicing   -- pages in hand, joining them onto the previous drain
    #   publishing -- writing the result and the caches derived from it
    #   done       -- published
    #   failed     -- gave up; `error` says why
    PHASES = %w[starting peeking draining splicing publishing done failed].freeze
    FINISHED_PHASES = %w[done failed].freeze

    # Which walk this is, which is what decides whether a viewer should be told
    # to sit tight (an incremental redrain is seconds) or warned (a reload is
    # minutes) -- and whether there are partial pages to show while it runs
    # (see BUFFERED_KINDS).
    #   cold        -- first-ever drain of this organization; full history
    #   incremental -- recent activity spliced onto the previous drain
    #   reload      -- full history, on explicit request, baseline ignored
    KINDS = %w[cold incremental reload].freeze

    # The kinds whose pages are kept as they land, so a viewer can render the
    # history fetched so far rather than a bar. An incremental walk's result
    # is a splice that only exists once it's finished.
    BUFFERED_KINDS = %w[cold reload].freeze

    # Where the task is running. "background" is a job; "inline" is a request
    # that had to drain on its own thread (an API call to an organization
    # nobody has opened, or a peek that spliced new rows in place).
    SOURCES = %w[background inline].freeze

    def initialize(cache_key)
      @key = "#{cache_key}:progress"
    end

    # The current record, or nil. `stalled` and `running` are derived on read
    # rather than stored, because they're statements about *now* and the record
    # by definition stops being updated exactly when it goes stale.
    def read
      record = Rails.cache.read(@key)
      return nil unless record.is_a?(Hash)

      finished = record[:phase].in?(FINISHED_PHASES)
      age = Time.now.to_f - record[:updated_at].to_f
      record.merge(
        running: !finished,
        stalled: finished ? false : age > STALE_AFTER,
        age: age.round(1)
      )
    end

    # Whether the record names a task that is still being advanced.
    def live?
      record = read
      record.present? && record[:running] && !record[:stalled]
    end

    def start!(kind:, source:, task_id: nil, requested_by: nil, total_count: nil)
      write({
        task_id: task_id,
        phase: "starting",
        kind: kind.to_s,
        source: source.to_s,
        requested_by: requested_by,
        pages_done: 0,
        transactions_done: 0,
        total_count: total_count,
        started_at: Time.now.to_f,
        finished_at: nil,
        error: nil
      })
    end

    # One page landed. Counts are absolute rather than deltas so a caller that
    # already knows its totals (a task resuming from the pages a dead one left
    # behind, a splice that inherited rows from the baseline) can state them
    # outright instead of reconstructing the increments that add up to them.
    def advance!(pages_done:, transactions_done:, total_count: nil, phase: "draining")
      current = Rails.cache.read(@key)
      current = {} unless current.is_a?(Hash)

      write(current.merge(
        phase: phase,
        pages_done: pages_done,
        transactions_done: transactions_done,
        # Held rather than overwritten with nil: HCB reports total_count on some
        # pages and not others, and a progress bar that loses its denominator
        # partway through is worse than one that never had it.
        total_count: total_count || current[:total_count]
      ).except(:stalled, :age, :running))
    end

    # Marks the phase without touching the counts -- for the parts of a drain
    # that aren't pages (joining onto the baseline, writing the side caches),
    # which are still time a watcher is spending and worth naming.
    def phase!(phase) = update!(phase: phase)

    # Rewrites named fields of the current record, leaving the rest as they are.
    def update!(fields)
      current = Rails.cache.read(@key)
      return unless current.is_a?(Hash)

      write(current.merge(fields.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v }).except(:stalled, :age, :running))
    end

    # Published. Kept for FINISHED_TTL so a tab opened later still sees what
    # the last load was, and so a poller sees the task reach the end rather than
    # the record disappearing out from under it.
    def finish!(count:)
      current = Rails.cache.read(@key)
      current = {} unless current.is_a?(Hash)

      write(
        current.merge(
          phase: "done",
          transactions_done: count,
          total_count: count,
          finished_at: Time.now.to_f
        ).except(:stalled, :age, :running),
        expires_in: FINISHED_TTL
      )
    end

    def fail!(message)
      current = Rails.cache.read(@key)
      current = {} unless current.is_a?(Hash)

      write(
        current.merge(phase: "failed", error: message.to_s.truncate(200), finished_at: Time.now.to_f).except(:stalled, :age, :running),
        expires_in: FINISHED_TTL
      )
    end

    def clear! = Rails.cache.delete(@key)

    private

    def write(record, expires_in: TTL)
      Rails.cache.write(@key, record.merge(updated_at: Time.now.to_f), expires_in: expires_in)
      record
    end
  end
end
