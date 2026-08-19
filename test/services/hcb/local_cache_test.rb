require "test_helper"

class Hcb::LocalCacheTest < ActiveSupport::TestCase
  setup { Hcb::LocalCache.clear }
  teardown { Hcb::LocalCache.clear }

  test "reads back what was written under the same version" do
    Hcb::LocalCache.write("k", "v1", [ 1, 2, 3 ])

    assert_equal [ 1, 2, 3 ], Hcb::LocalCache.read("k", "v1")
  end

  test "a different version misses rather than serving the previous drain" do
    Hcb::LocalCache.write("k", "v1", [ 1, 2, 3 ])

    assert_nil Hcb::LocalCache.read("k", "v2")
  end

  test "a blank version neither reads nor writes -- there is nothing to invalidate against" do
    # Writes still hand the value straight back, so callers can read through
    # this without branching on whether it was actually stored.
    assert_equal [ 1, 2, 3 ], Hcb::LocalCache.write("k", nil, [ 1, 2, 3 ])

    assert_nil Hcb::LocalCache.read("k", nil)
    assert_nil Hcb::LocalCache.read("k", "v1")
  end

  test "nil is not stored, so a missing side cache isn't remembered as missing" do
    assert_nil Hcb::LocalCache.write("k", "v1", nil)
    assert_nil Hcb::LocalCache.read("k", "v1")
  end

  test "entries are frozen, since readers share one object instead of getting copies" do
    value = Hcb::LocalCache.write("k", "v1", { "a" => 1 })

    assert_predicate value, :frozen?
    assert_predicate Hcb::LocalCache.read("k", "v1"), :frozen?
  end

  test "the size cap evicts the least recently used entry" do
    keys = (1..Hcb::LocalCache::MAX_ENTRIES).map { |n| "k#{n}" }
    keys.each { |key| Hcb::LocalCache.write(key, "v1", [ key ]) }

    # Touching the oldest makes it the newest, so the *second* oldest is what
    # the next write pushes out.
    assert_equal [ keys.first ], Hcb::LocalCache.read(keys.first, "v1")
    Hcb::LocalCache.write("overflow", "v1", [ "overflow" ])

    assert_equal [ keys.first ], Hcb::LocalCache.read(keys.first, "v1")
    assert_nil Hcb::LocalCache.read(keys.second, "v1")
    assert_equal [ "overflow" ], Hcb::LocalCache.read("overflow", "v1")
  end
end
