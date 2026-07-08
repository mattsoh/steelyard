require "test_helper"

class Hcb::OrganizationTransactionsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "page forwards search filters and cursor params" do
    client = FakeHcbClient.new(
      transactions: [
        { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation from Alice", "amount_cents" => 1_000 },
        { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant payment", "amount_cents" => 2_000 }
      ]
    )

    service = Hcb::OrganizationTransactions.new(client, "org_1", filters: { search: "donation" })

    page = service.page(limit: 1)

    assert_equal [ "txn_1" ], page["data"].map { |tx| tx["id"] }
    assert_equal 1, page["total_count"]
    assert_equal 1, client.transactions_calls
  end

  test "all caches the full filtered transaction list per organization" do
    client = FakeHcbClient.new(
      transactions: [
        { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation from Alice", "amount_cents" => 1_000 },
        { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant payment", "amount_cents" => 2_000 }
      ]
    )

    service = Hcb::OrganizationTransactions.new(client, "org_1", filters: { search: "grant" })

    first = service.all
    second = service.all

    assert_equal first, second
    assert_equal [ "txn_2" ], first.map { |tx| tx["id"] }
    assert_equal 1, client.transactions_calls
  end

  test "fetch_page drains one page at a time and primes the cache #all reads from" do
    client = FakeHcbClient.new(
      transactions: [
        { "id" => "txn_3", "date" => "2026-01-03", "memo" => "C", "amount_cents" => 300 },
        { "id" => "txn_2", "date" => "2026-01-02", "memo" => "B", "amount_cents" => 200 },
        { "id" => "txn_1", "date" => "2026-01-01", "memo" => "A", "amount_cents" => 100 }
      ]
    )
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    first = service.fetch_page(stream_id: "s1", limit: 1)
    assert_equal [ "txn_3" ], first[:data].map { |t| t["id"] }
    assert first[:has_more]
    assert_equal "txn_3", first[:next_after]

    second = service.fetch_page(stream_id: "s1", after: first[:next_after], limit: 1)
    assert_equal [ "txn_2" ], second[:data].map { |t| t["id"] }
    assert second[:has_more]

    third = service.fetch_page(stream_id: "s1", after: second[:next_after], limit: 1)
    assert_equal [ "txn_1" ], third[:data].map { |t| t["id"] }
    assert_not third[:has_more]
    assert_nil third[:next_after]

    # The buffered pages should now be cached under the same key #all uses --
    # a follow-up #all shouldn't hit HCB again.
    calls_before = client.transactions_calls
    assert_equal [ "txn_3", "txn_2", "txn_1" ], service.all.map { |t| t["id"] }
    assert_equal calls_before, client.transactions_calls
  end

  test "fetch_page short-circuits to the warm cache instead of re-draining" do
    client = FakeHcbClient.new(
      transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "memo" => "A", "amount_cents" => 100 } ]
    )
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    calls_before = client.transactions_calls
    result = service.fetch_page(stream_id: "s2")

    assert_equal [ "txn_1" ], result[:data].map { |t| t["id"] }
    assert_not result[:has_more]
    assert_equal calls_before, client.transactions_calls
  end

  test "all enqueues a background refresh once the cached entry is due for a check" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    client = FakeHcbClient.new(
      transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "memo" => "A", "amount_cents" => 100 } ],
      user_id: user.id
    )
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    travel(Hcb::OrganizationTransactions::BACKGROUND_REFRESH_INTERVAL + 1.second) do
      assert_enqueued_with(job: WarmOrganizationTransactionsJob, args: [ user.id, "org_1", { filters: {} } ]) do
        service.all
      end
    end
  end

  test "all does not enqueue a background refresh before the check interval has elapsed" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    client = FakeHcbClient.new(
      transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "memo" => "A", "amount_cents" => 100 } ],
      user_id: user.id
    )
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    travel(Hcb::OrganizationTransactions::BACKGROUND_REFRESH_INTERVAL - 1.second) do
      assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) { service.all }
    end
  end

  test "all does not enqueue a background refresh when the client can't identify a user" do
    client = FakeHcbClient.new(
      transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "memo" => "A", "amount_cents" => 100 } ]
    )
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    travel(Hcb::OrganizationTransactions::BACKGROUND_REFRESH_INTERVAL + 1.second) do
      assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) { service.all }
    end
  end

  test "refresh! incrementally redrains: only walks recent activity plus the safety overlap, not full history" do
    old_transactions = (1..500).map { |n| { "id" => "txn_old_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    baseline = service.all
    assert_equal 500, baseline.size
    full_drain_calls = client.transactions_calls

    new_transactions = (1..50).map { |n| { "id" => "txn_new_#{n}", "date" => "2026-02-01", "amount_cents" => n } }.reverse
    client.add_transactions(new_transactions)

    calls_before_refresh = client.transactions_calls
    result = service.refresh!
    calls_during_refresh = client.transactions_calls - calls_before_refresh

    assert_equal 550, result.size
    assert_equal new_transactions.map { |t| t["id"] } + old_transactions.map { |t| t["id"] }, result.map { |t| t["id"] }

    # A full drain of 550 transactions at PAGE_SIZE 100 takes 6 requests; the
    # incremental redrain should need far fewer since it only walks the new
    # 50 plus the SAFETY_OVERLAP (300) before splicing onto the baseline.
    assert_operator calls_during_refresh, :<, full_drain_calls + 1
    assert_equal 3, calls_during_refresh
  end

  test "all reuses the long-lived baseline for an incremental redrain once the primary cache has expired" do
    old_transactions = (1..500).map { |n| { "id" => "txn_old_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    service.all

    new_transactions = [ { "id" => "txn_new_1", "date" => "2026-02-01", "amount_cents" => 1 } ]
    client.add_transactions(new_transactions)

    travel(Hcb::OrganizationTransactions::TTL + 1.second) do
      calls_before = client.transactions_calls
      result = service.all
      calls_during = client.transactions_calls - calls_before

      assert_equal 501, result.size
      assert_equal "txn_new_1", result.first["id"]
      assert_operator calls_during, :<, 6 # a full 501-item drain would take 6 requests
    end
  end

  test "incremental redrain falls back to a full drain when there is no baseline" do
    transactions = (1..250).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    result = service.refresh!

    assert_equal transactions.map { |t| t["id"] }, result.map { |t| t["id"] }
    assert_equal 3, client.transactions_calls # ceil(250 / 100)
  end

  test "fetch_page reuses the baseline for an incremental rejoin once the primary cache has expired" do
    old_transactions = (1..500).map { |n| { "id" => "txn_old_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    service.all

    new_transactions = [ { "id" => "txn_new_1", "date" => "2026-02-01", "amount_cents" => 1 } ]
    client.add_transactions(new_transactions)

    travel(Hcb::OrganizationTransactions::TTL + 1.second) do
      calls_before = client.transactions_calls
      result = service.fetch_page(stream_id: "s3")
      calls_during = client.transactions_calls - calls_before

      assert_equal 501, result[:data].size
      assert_equal "txn_new_1", result[:data].first["id"]
      assert_not result[:has_more]
      assert_operator calls_during, :<, 6 # a full 501-item drain would take 6 requests
    end
  end

  test "fetch_page buffers concurrent drains separately by stream_id" do
    client = FakeHcbClient.new(
      transactions: [
        { "id" => "txn_2", "date" => "2026-01-02", "memo" => "B", "amount_cents" => 200 },
        { "id" => "txn_1", "date" => "2026-01-01", "memo" => "A", "amount_cents" => 100 }
      ]
    )
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    a_first = service.fetch_page(stream_id: "a", limit: 1)
    b_first = service.fetch_page(stream_id: "b", limit: 1)
    assert_equal a_first[:data], b_first[:data]

    a_second = service.fetch_page(stream_id: "a", after: a_first[:next_after], limit: 1)
    assert_not a_second[:has_more]

    assert_equal [ "txn_2", "txn_1" ], service.all.map { |t| t["id"] }
  end
end
