module Hcb
  # Process-local memo in front of Rails.cache, for the handful of entries
  # that are both read on nearly every request and megabytes of Ruby objects
  # once deserialized (an organization's whole drained transaction history and
  # the side indexes built from it).
  #
  # Rails.cache.read of one of those is never cheap, whatever the store is
  # behind it: the bytes have to be inflated (entries over 1kB are Zlib'd by
  # default) and Marshal-loaded into a fresh object graph on *every* request,
  # in *every* process, even when nothing has changed since the last drain.
  # That cost is Ruby-side, so no amount of making the store itself faster
  # touches it -- the only way not to pay it is not to do it again.
  #
  # Correctness rests on the version token: every OrganizationTransactions
  # #publish stamps a fresh token alongside the result, and callers pass the
  # token they read from that (small, cheap) stamp. Any new drain -- in a
  # warming job, in another web worker, in a #sync_head! splice -- changes the
  # token, so every process's copy of the previous drain is ignored on the
  # next request rather than served stale. Reading the stamp is the one store
  # round trip a warm request can't avoid, and it's a few dozen bytes.
  #
  # A blank token (nothing published yet, or a store that doesn't persist --
  # :null_store in test) disables the memo entirely and callers fall through
  # to Rails.cache, which is what they did before this existed.
  #
  # Unlike Rails.cache.read, two callers get the *same* object rather than
  # private deep copies -- that's the whole point, and it's why entries are
  # frozen on the way in. Everything stored here is drain output that callers
  # only ever read from. Freezing is shallow (the rows inside an entry aren't
  # frozen, since walking megabytes of nested hashes to freeze them would give
  # back some of what this saves), so the contract is: don't mutate what you
  # read out of a drain cache.
  class LocalCache
    # Entries are whole org histories, so this bounds how much memory each
    # worker can hold: roughly this many drains' worth across all the
    # organizations one process happens to serve. Small on purpose -- an
    # org that stops being looked at should stop costing memory reasonably
    # soon, and the cost of an eviction is just one Rails.cache read.
    MAX_ENTRIES = ENV.fetch("STEELYARD_LOCAL_CACHE_ENTRIES", 12).to_i

    MUTEX = Mutex.new
    @entries = {}

    class << self
      def read(key, version)
        return nil if version.blank? || MAX_ENTRIES <= 0

        MUTEX.synchronize do
          stored_version, value = @entries[key]
          next nil unless stored_version == version

          # Ruby hashes iterate in insertion order and #shift drops the oldest,
          # so re-inserting on a hit is what makes the size cap evict the
          # least-recently-*used* entry rather than the least-recently-written.
          @entries.delete(key)
          @entries[key] = [ stored_version, value ]
          value
        end
      end

      # nil is never stored: for every key this fronts, nil means "not written
      # for the current drain", which is a state callers already handle by
      # falling back -- and caching it would mean holding that answer until the
      # next drain even after the side caches land.
      def write(key, version, value)
        return value if version.blank? || MAX_ENTRIES <= 0 || value.nil?

        value.freeze
        MUTEX.synchronize do
          @entries.delete(key)
          @entries[key] = [ version, value ]
          @entries.shift while @entries.size > MAX_ENTRIES
        end
        value
      end

      def clear = MUTEX.synchronize { @entries.clear }
    end
  end
end
