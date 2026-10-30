require "test_helper"

class Hcb::ActivityLogTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @log = Hcb::ActivityLog.new("hcb:org:org_1:test")
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "lines are numbered in order and readable from a seq onwards" do
    @log.append("one")
    @log.append("two", kind: "warn", task_id: "t1")
    @log.append("three", kind: "done")

    all = @log.read
    assert_equal [ 1, 2, 3 ], all.map { |e| e[:seq] }
    assert_equal [ "info", "warn", "done" ], all.map { |e| e[:kind] }
    assert_equal "t1", all[1][:task_id]
    assert all.all? { |e| e[:at].is_a?(Float) }

    assert_equal [ "three" ], @log.read(after: 2).map { |e| e[:text] }
    assert_equal [], @log.read(after: 3)
    assert_equal 3, @log.last_seq
  end

  test "another reader of the same key sees the same lines" do
    @log.append("shared")
    assert_equal [ "shared" ], Hcb::ActivityLog.new("hcb:org:org_1:test").read.map { |e| e[:text] }
  end

  test "the oldest lines drop off once the cap is reached, and seqs keep counting" do
    (Hcb::ActivityLog::MAX_ENTRIES + 5).times { |i| @log.append("line #{i}") }

    entries = @log.read
    assert_equal Hcb::ActivityLog::MAX_ENTRIES, entries.size
    assert_equal "line 5", entries.first[:text]
    assert_equal Hcb::ActivityLog::MAX_ENTRIES + 5, entries.last[:seq]
  end

  test "an empty or missing log reads as nothing rather than failing" do
    assert_equal [], @log.read
    assert_equal 0, @log.last_seq
    @log.clear!
    assert_equal [], @log.read(after: 10)
  end
end
