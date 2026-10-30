module Hcb
  # What has been happening to one organization's HCB data, as a log anyone
  # can read -- not just the tab that happened to be open when it happened.
  #
  # The activity panel on the matcher and the ledger used to be built entirely
  # in the browser, out of the responses that one tab received. That was fine
  # while the tab itself drove the walk, and useless the moment it didn't: open
  # a second tab, or come back to an organization somebody else is loading, and
  # the panel said "Nothing yet" over a drain that was forty pages in. Now the
  # walk runs in a background task (see OrganizationTransactions#run_task!) and
  # the task writes here as it goes, so every tab reads the same account of it
  # -- including a tab opened after it finished, which is how "what happened to
  # this organization an hour ago?" gets answered.
  #
  # Cache-backed, like everything else about a drain, and advisory: nothing
  # reads it to decide anything. Losing it costs history, not data.
  class ActivityLog
    # Enough to cover a long full reload (one line per page) and the checks
    # around it, without growing without bound on a busy organization. Oldest
    # lines drop off the top.
    MAX_ENTRIES = ENV.fetch("HCB_ACTIVITY_LOG_ENTRIES", 300).to_i

    # How long the log survives the last thing written to it. A day covers
    # "what happened this morning?"; the drain caches it describes are gone long
    # before that anyway.
    TTL = 1.day

    # Same vocabulary as the browser-side log (activity.js), so the two render
    # through one code path: "info", "hcb" for something HCB did, "warn" for
    # something worth noticing, "error" for a failure, "done" for a finish.
    KINDS = %w[info hcb warn error done].freeze

    def initialize(cache_key)
      @key = "#{cache_key}:activity:v1"
    end

    # Appends one line. `task_id` ties a line to the task that wrote it, so a
    # reader can tell the pages of one load from the pages of the next.
    #
    # Read-modify-write without a lock: the task holding the organization's
    # claim is the only steady writer, and the inline paths that also log (a
    # peek, a single re-fetch) are rare enough that a lost line is a tolerable
    # price for not serialising every page of a drain on a lock.
    def append(text, kind: "info", task_id: nil)
      record = read_record
      seq = record[:seq] + 1
      entry = { seq: seq, at: Time.now.to_f, kind: kind.to_s, text: text.to_s.truncate(500), task_id: task_id }
      entries = record[:entries] + [ entry ]
      entries.shift while entries.size > MAX_ENTRIES

      Rails.cache.write(@key, { seq: seq, entries: entries }, expires_in: TTL)
      entry
    end

    # Everything after `after` (a seq a reader has already seen), oldest first.
    # A reader polling for progress passes the last seq it rendered and gets
    # only what is new, which keeps a poll a few hundred bytes instead of the
    # whole history every second.
    def read(after: nil)
      entries = read_record[:entries]
      return entries if after.blank?

      cutoff = after.to_i
      entries.select { |e| e[:seq] > cutoff }
    end

    # The seq of the newest line, which is what a reader hands back as `after`
    # on its next poll.
    def last_seq = read_record[:seq]

    def clear! = Rails.cache.delete(@key)

    private

    def read_record
      record = Rails.cache.read(@key)
      return { seq: 0, entries: [] } unless record.is_a?(Hash) && record[:entries].is_a?(Array)

      record
    end
  end
end
