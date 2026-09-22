module Hcb
  # How far along the organization's current drain is, in a form anything can
  # read without touching HCB.
  #
  # Before this, a drain was opaque from the outside: Hcb::OrganizationTransactions
  # #sync_state could say when the *last* result was published and how big it
  # was, which answers "has it landed yet?" but nothing at all about a drain
  # still running. A viewer waiting on one got a spinner and a guess -- and a
  # spinner looks identical whether the walk is on page 2 of 60, finished ten
  # seconds ago, or died with the tab that started it.
  #
  # So every path that walks HCB stamps its progress here as it goes, and
  # Api::TransactionsController#sync_status hands it straight back. That makes
  # the same record answer for all of them -- a browser-driven stream, a
  # background warm, a full reload, a reload a job took over mid-walk -- which
  # is what lets a second tab (or the tab that just came back from being closed)
  # show the drain someone else is driving rather than starting its own.
  #
  # Cache-backed and advisory. It is written on the same schedule as the pages
  # it describes (a few hundred milliseconds apart at worst), never read to make
  # a decision about *data*, and losing it costs a progress bar, not a drain.
  class DrainProgress
    # Long enough to outlive the gap between two slow HCB pages many times over,
    # short enough that a record nobody is advancing any more disappears rather
    # than sitting there describing a drain that died.
    TTL = 15.minutes

    # No update in this long means whoever was writing it has gone -- a killed
    # worker, a tab closed before the handoff beacon got out. Readers show it as
    # stalled rather than as live progress, which is the difference between
    # "still going, wait" and "nothing is coming, start one".
    STALE_AFTER = ENV.fetch("HCB_DRAIN_PROGRESS_STALE_AFTER", 75).to_i.seconds

    # What the drain is doing right now. Only ever shown to a human -- nothing
    # branches on these.
    #   starting   -- claimed, nothing fetched yet
    #   peeking    -- one page, asking whether anything is new (#sync_head!)
    #   draining   -- walking pages from HCB
    #   splicing   -- pages in hand, joining them onto the previous drain
    #   publishing -- writing the result and the caches derived from it
    #   done       -- published; the record survives briefly so a poller can see
    #                 it finish rather than just vanish
    #   failed     -- gave up; `error` says why
    PHASES = %w[starting peeking draining splicing publishing done failed].freeze

    # Which walk this is, which is what decides whether a viewer should be told
    # to sit tight (an incremental redrain is seconds) or warned (a reload is
    # minutes).
    #   cold        -- first-ever drain of this organization; full history
    #   incremental -- recent activity spliced onto the previous drain
    #   reload      -- full history, on explicit request, baseline ignored
    KINDS = %w[cold incremental reload].freeze

    # Who is driving it, so the page can say whether closing the tab would stop
    # it. "browser" is a stream this app is serving page by page to a tab;
    # "background" is a Solid Queue job, which no tab can interrupt.
    SOURCES = %w[browser background].freeze

    def initialize(cache_key)
      @key = "#{cache_key}:progress"
    end

    # The current record, or nil. `stalled` is derived on read rather than
    # stored, because it's a statement about *now* and the record by definition
    # stops being updated exactly when it becomes true.
    def read
      record = Rails.cache.read(@key)
      return nil unless record.is_a?(Hash)

      age = Time.now.to_f - record[:updated_at].to_f
      record.merge(
        stalled: record[:phase].in?(%w[done failed]) ? false : age > STALE_AFTER,
        age: age.round(1)
      )
    end

    def start!(kind:, source:, stream_id: nil, total_count: nil)
      write({
        phase: "starting",
        kind: kind.to_s,
        source: source.to_s,
        stream_id: stream_id,
        pages_done: 0,
        transactions_done: 0,
        total_count: total_count,
        started_at: Time.now.to_f,
        error: nil
      })
    end

    # One page landed. Counts are absolute rather than deltas so a caller that
    # already knows its totals (a stream resuming from a buffer, a splice that
    # inherited rows from the baseline) can state them outright instead of
    # trying to reconstruct the increments that would add up to them.
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
      ).except(:stalled, :age))
    end

    # Marks the phase without touching the counts -- for the parts of a drain
    # that aren't pages (joining onto the baseline, writing the side caches),
    # which are still time a watcher is spending and worth naming.
    def phase!(phase)
      current = Rails.cache.read(@key)
      return unless current.is_a?(Hash)

      write(current.merge(phase: phase).except(:stalled, :age))
    end

    # Published. Kept (briefly) rather than deleted so a poller sees the drain
    # reach the end instead of the record disappearing out from under it, which
    # is indistinguishable from the drain dying.
    def finish!(count:)
      current = Rails.cache.read(@key)
      current = {} unless current.is_a?(Hash)

      write(
        current.merge(
          phase: "done",
          transactions_done: count,
          total_count: count,
          finished_at: Time.now.to_f
        ).except(:stalled, :age),
        expires_in: 1.minute
      )
    end

    def fail!(message)
      current = Rails.cache.read(@key)
      current = {} unless current.is_a?(Hash)

      write(
        current.merge(phase: "failed", error: message.to_s.truncate(200)).except(:stalled, :age),
        expires_in: 2.minutes
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
