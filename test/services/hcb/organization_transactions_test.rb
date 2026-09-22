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

  # Records every cursor asked for, so a test can assert a redrain named its
  # page boundaries from the baseline (the concurrent path) rather than
  # discovering each one from the page before it (the serial walk). Which
  # cursors were used is the only externally visible difference between the
  # two: both make the same number of requests and return the same result.
  class CursorRecordingClient < FakeHcbClient
    def cursors = @cursors ||= Queue.new

    def transactions(organization_id, after: nil, limit: 100, filters: {})
      cursors << after
      super
    end

    def cursors_asked
      asked = []
      asked << cursors.pop until cursors.empty?
      asked
    end
  end

  def five_hundred_old_transactions
    (1..500).map { |n| { "id" => "txn_old_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
  end

  test "an incremental redrain names its page boundaries from the baseline instead of waiting for each cursor" do
    old_transactions = five_hundred_old_transactions
    client = CursorRecordingClient.new(transactions: old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    new_transactions = (1..50).map { |n| { "id" => "txn_new_#{n}", "date" => "2026-02-01", "amount_cents" => n } }.reverse
    client.add_transactions(new_transactions)
    client.cursors_asked

    result = service.refresh!

    # 50 landed, so the first page carries them plus the baseline's newest 50 --
    # leaving the rest of the 300-transaction overlap window to be fetched from
    # baseline positions 49 and 149. A serial walk would instead have had to ask
    # for txn_old_351 only after the page ending at txn_old_451 came back.
    assert_equal [ nil, "txn_old_451", "txn_old_351" ], client.cursors_asked
    assert_equal new_transactions.map { |t| t["id"] } + old_transactions.map { |t| t["id"] }, result.map { |t| t["id"] }
  end

  test "an incremental redrain still picks up an in-place change inside the overlap window" do
    client = CursorRecordingClient.new(transactions: five_hundred_old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    # Still at its baseline position, so the window tiles and the cheap
    # concurrent path is taken -- but the copy that lands has to be HCB's.
    client.update_transaction("txn_old_400", "declined" => true, "amount_cents" => 0)
    client.cursors_asked

    result = service.refresh!

    # Nothing landed, so the overlap window's page boundaries are the baseline's
    # own: positions 99 and 199, both named up front rather than waited for.
    assert_equal [ nil, "txn_old_401", "txn_old_301" ], client.cursors_asked
    changed = result.find { |t| t["id"] == "txn_old_400" }
    assert changed["declined"]
    assert_equal 0, changed["amount_cents"]
    assert_equal 500, result.size
  end

  test "an incremental redrain falls back to walking cursors when more than a page of activity has landed" do
    old_transactions = five_hundred_old_transactions
    client = CursorRecordingClient.new(transactions: old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    # The baseline's newest transaction no longer appears in HCB's newest page,
    # so there's no way to read off how far the list has shifted -- and cursors
    # picked from the baseline would leave a gap in the middle of the result.
    new_transactions = (1..150).map { |n| { "id" => "txn_new_#{n}", "date" => "2026-02-01", "amount_cents" => n } }.reverse
    client.add_transactions(new_transactions)
    client.cursors_asked

    result = service.refresh!

    assert_equal new_transactions.map { |t| t["id"] } + old_transactions.map { |t| t["id"] }, result.map { |t| t["id"] }
    assert_equal 650, result.size
  end

  test "an incremental redrain falls back to walking cursors when the baseline has diverged mid-window" do
    old_transactions = five_hundred_old_transactions
    client = CursorRecordingClient.new(transactions: old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    # Gone from HCB, so every baseline position after it is off by one and the
    # window no longer tiles. Splicing on the guessed boundaries would drop a
    # transaction, which is a wrong running balance -- so this has to walk.
    client.remove_transaction("txn_old_480")

    result = service.refresh!

    assert_equal 499, result.size
    assert_not_includes result.map { |t| t["id"] }, "txn_old_480"
    assert_equal old_transactions.map { |t| t["id"] } - [ "txn_old_480" ], result.map { |t| t["id"] }
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

  test "sync_head! reports fresh from a single peek when nothing has landed since the drain" do
    transactions = (1..250).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    calls_before = client.transactions_calls
    assert_equal :fresh, service.sync_head!
    assert_equal 1, client.transactions_calls - calls_before
  end

  test "sync_head! splices newly-landed transactions into the cache from a single peek" do
    old_transactions = (1..500).map { |n| { "id" => "txn_old_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    client.add_transactions([ { "id" => "txn_new_1", "date" => "2026-02-01", "amount_cents" => 1 } ])

    calls_before = client.transactions_calls
    assert_equal :synced, service.sync_head!
    # The whole point: one request, versus the 3 an incremental redrain needs
    # just to cover SAFETY_OVERLAP before it can look for a rejoin point.
    assert_equal 1, client.transactions_calls - calls_before

    cached = Hcb::OrganizationTransactions.new(client, "org_1").all
    assert_equal 501, cached.size
    assert_equal "txn_new_1", cached.first["id"]
  end

  test "sync_head! picks up an in-place change to a transaction the drain already cached" do
    client = FakeHcbClient.new(transactions: [
      { "id" => "txn_2", "date" => "2026-01-02", "amount_cents" => 200 },
      { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 100 }
    ])
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    client.update_transaction("txn_2", "declined" => true)

    assert_equal :synced, service.sync_head!
    cached = Hcb::OrganizationTransactions.new(client, "org_1").all
    assert_equal [ "txn_2", "txn_1" ], cached.map { |t| t["id"] }
    assert_equal true, cached.first["declined"]
  end

  test "sync_head! defers to a full redrain when more landed than one peek can account for" do
    old_transactions = (1..500).map { |n| { "id" => "txn_old_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    new_transactions = (1..150).map { |n| { "id" => "txn_new_#{n}", "date" => "2026-02-01", "amount_cents" => n } }.reverse
    client.add_transactions(new_transactions)

    assert_equal :deep, service.sync_head!
  end

  test "sync_head! defers to a full redrain without peeking when there is no cache to compare against" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 100 } ])
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    assert_equal :deep, service.sync_head!
    assert_equal 0, client.transactions_calls
  end

  test "sync_head! leaves the cache alone when it reports fresh" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 100 } ])
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all
    stamp_before = service.sync_state.except(:progress)

    travel(1.minute) do
      assert_equal :fresh, Hcb::OrganizationTransactions.new(client, "org_1").sync_head!
      after = Hcb::OrganizationTransactions.new(client, "org_1").sync_state
      assert_equal stamp_before, after.except(:progress)
      # A peek that finds nothing must leave the previous drain's record alone
      # rather than replacing it with a walk that never happened.
      assert_equal "done", after[:progress][:phase]
    end
  end

  test "sync_state stamps every published result so a poller can tell when the drain moved" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 100 } ])
    Hcb::OrganizationTransactions.new(client, "org_1").all

    before = Hcb::OrganizationTransactions.new(client, "org_1").sync_state
    assert_equal 1, before[:count]
    assert before[:fetched_at]

    client.add_transactions([ { "id" => "txn_2", "date" => "2026-01-02", "amount_cents" => 200 } ])

    travel(1.minute) do
      assert_equal :synced, Hcb::OrganizationTransactions.new(client, "org_1").sync_head!
      after = Hcb::OrganizationTransactions.new(client, "org_1").sync_state
      assert_equal 2, after[:count]
      assert_not_equal before[:fetched_at], after[:fetched_at]
    end
  end

  test "sync_state reports nothing cached before any drain has run" do
    client = FakeHcbClient.new(transactions: [])
    assert_equal(
      { fetched_at: nil, count: nil, token: nil, reloading: false, draining: false, drain_kind: nil, progress: nil },
      Hcb::OrganizationTransactions.new(client, "org_1").sync_state
    )
  end

  test "purge! drops the baseline, so a reload can't be undone by the next ordinary redrain" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    service.purge!

    # HCB has dropped one since. With the baseline still around, an incremental
    # redrain would splice the old copy of it straight back on -- which is the
    # stale value someone reached for a full reload to be rid of.
    client.remove_transaction("txn_2")
    result = Hcb::OrganizationTransactions.new(client, "org_1").all

    assert_equal [ "txn_3", "txn_1" ], result.map { |t| t["id"] }
  end

  test "purge! leaves nothing of the previous drain to be answered from" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all
    assert service.find("txn_1")
    assert service.presented
    assert service.derived
    assert service.ledger_order
    assert service.sync_state[:fetched_at]

    service.purge!

    fresh = Hcb::OrganizationTransactions.new(client, "org_1")
    assert_nil fresh.find("txn_1")
    assert_nil fresh.presented
    assert_nil fresh.derived
    assert_nil fresh.ledger_order
    assert_nil fresh.sync_state[:fetched_at]
  end

  test "a claimed full reload stops every other path from draining the same history again" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.claim_full_reload!("stream-1")
    service.purge!

    calls_before = client.transactions_calls
    other = Hcb::OrganizationTransactions.new(client, "org_1")

    # Nothing cached and no baseline, so without the claim check each of these
    # would start its own full walk of the org's history -- exactly the
    # duplicate rate-limit spend the claim exists to prevent.
    assert_empty other.all
    assert_equal :reloading, other.sync_head!

    first_page = other.fetch_page(stream_id: "bystander")
    assert first_page[:reloading]
    assert_empty first_page[:data]

    # Mid-stream too: a reload claimed after someone started paging must not
    # leave them walking the whole history alongside it.
    mid_stream = other.fetch_page(stream_id: "bystander", after: "txn_3")
    assert mid_stream[:reloading]

    assert_equal calls_before, client.transactions_calls
    assert other.sync_state[:reloading]
  end

  test "a claimed full reload stops the background refresh being queued on top of it" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ], user_id: 7)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.claim_full_reload!("stream-1")
    service.purge!

    # A purged cache reads as maximally stale, so without the check this would
    # queue a redrain on every request for the whole duration of the reload --
    # each one publishing a fetched_at the reloading tab reads as its own drain
    # having landed.
    assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
      Hcb::OrganizationTransactions.new(client, "org_1").all
    end
  end

  test "the tab holding the claim still streams its reload against the purged cache" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.claim_full_reload!("stream-1")
    service.purge!

    first = service.fetch_page(stream_id: "stream-1", limit: 1, reload: true)
    assert_not first[:reloading]
    assert_equal 1, first[:data].size

    second = service.fetch_page(stream_id: "stream-1", after: first[:next_after], limit: 1, reload: true)
    service.fetch_page(stream_id: "stream-1", after: second[:next_after], limit: 1, reload: true)

    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
    assert_not service.sync_state[:reloading]
  end

  test "reload-mode pages re-walk history from HCB rather than answering from the warm cache" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all # cache and baseline both warm now

    assert service.claim_full_reload!("stream-1")
    calls_before = client.transactions_calls

    first = service.fetch_page(stream_id: "stream-1", limit: 1, reload: true)

    # The whole point of a full reload is not trusting what's cached, so the
    # short-circuits an ordinary stream takes have to be skipped: one page's
    # worth of rows, and a request actually made for them.
    assert_equal 1, first[:data].size
    assert first[:has_more]
    assert_equal 1, client.transactions_calls - calls_before
  end

  test "a reload-mode stream publishes only once its last page lands" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.claim_full_reload!("stream-1")

    first = service.fetch_page(stream_id: "stream-1", limit: 1, reload: true)
    # A partial walk must not become the authoritative result -- a drain missing
    # its older half is a wrong running balance for every row above it.
    assert_nil service.sync_state[:fetched_at]

    second = service.fetch_page(stream_id: "stream-1", after: first[:next_after], limit: 1, reload: true)
    assert_nil service.sync_state[:fetched_at]

    service.fetch_page(stream_id: "stream-1", after: second[:next_after], limit: 1, reload: true)

    assert_equal 3, service.sync_state[:count]
    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
    # Released on the way out, so the next reload can be claimed.
    assert_nil service.full_reload_claim
  end

  test "reload mode is only offered to the stream holding the claim" do
    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: []), "org_1")

    assert service.claim_full_reload!("stream-1")
    assert service.full_reload_stream?("stream-1")
    # Another tab asking for a full re-walk of its own would double the cost
    # against a rate limit the whole organization shares.
    assert_not service.full_reload_stream?("stream-2")
    assert_not service.full_reload_stream?("")
    # And nobody else can claim it while it's held.
    assert_not service.claim_full_reload!("stream-2")
  end

  test "resume_stream! finishes an abandoned stream from the pages it had already buffered" do
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.claim_full_reload!("stream-1")

    # Two pages in, then the tab goes away.
    first = service.fetch_page(stream_id: "stream-1", limit: 2, reload: true)
    service.fetch_page(stream_id: "stream-1", after: first[:next_after], limit: 2, reload: true)
    assert_nil service.sync_state[:fetched_at]

    calls_before = client.transactions_calls
    outcome = travel(Hcb::OrganizationTransactions::STREAM_HEARTBEAT_TIMEOUT + 1.second) do
      service.resume_stream!("stream-1")
    end

    assert_equal :resumed, outcome
    # Picked up where the stream stopped rather than starting the walk again:
    # one more request finishes the remaining transaction.
    assert_equal 1, client.transactions_calls - calls_before
    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
    assert_nil service.full_reload_claim
  end

  test "resume_stream! leaves a stream that is still being driven alone" do
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.claim_full_reload!("stream-1")
    service.fetch_page(stream_id: "stream-1", limit: 2, reload: true)

    calls_before = client.transactions_calls

    # Draining alongside a live stream would spend the shared rate limit twice
    # over on the same history.
    assert_equal :running, service.resume_stream!("stream-1")
    assert_equal calls_before, client.transactions_calls
    assert_nil service.sync_state[:fetched_at]
  end

  test "resume_stream! is a no-op once the stream has published and released" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.claim_full_reload!("stream-1")
    service.fetch_page(stream_id: "stream-1", reload: true)

    calls_before = client.transactions_calls

    assert_equal :done, service.resume_stream!("stream-1")
    assert_equal calls_before, client.transactions_calls
  end

  test "a second stream waits for the walk already running instead of buying a second copy of it" do
    client = FakeHcbClient.new(
      transactions: [
        { "id" => "txn_2", "date" => "2026-01-02", "memo" => "B", "amount_cents" => 200 },
        { "id" => "txn_1", "date" => "2026-01-01", "memo" => "A", "amount_cents" => 100 }
      ]
    )
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    a_first = service.fetch_page(stream_id: "a", limit: 1)
    assert_equal [ "txn_2" ], a_first[:data].map { |t| t["id"] }

    # Two tabs opening the same cold organization used to each walk the whole
    # history, against a rate limit they share with everybody else.
    calls_before = client.transactions_calls
    b_first = service.fetch_page(stream_id: "b", limit: 1)
    assert b_first[:waiting]
    assert_empty b_first[:data]
    assert_equal calls_before, client.transactions_calls

    a_second = service.fetch_page(stream_id: "a", after: a_first[:next_after], limit: 1)
    assert_not a_second[:has_more]

    assert_equal [ "txn_2", "txn_1" ], service.all.map { |t| t["id"] }
  end

  test "a stream that lost its claim mid-walk stops rather than publishing over the owner" do
    transactions = (1..4).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    first = service.fetch_page(stream_id: "a", limit: 1)
    assert first[:has_more]

    # The fallback job takes the walk over after the tab driving it goes quiet.
    service.release_stream!
    service.claim_stream!("takeover", kind: :cold)

    calls_before = client.transactions_calls
    orphaned = service.fetch_page(stream_id: "a", after: first[:next_after], limit: 1)

    assert orphaned[:waiting]
    assert_empty orphaned[:data]
    assert_equal calls_before, client.transactions_calls
    assert_nil service.sync_state[:fetched_at]
  end

  # --- a walk that outlives the tab driving it -------------------------------

  test "an abandoned cold stream is finished from the pages it had already buffered" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    # A tab opens a cold organization, streams two pages, then goes away.
    first = service.fetch_page(stream_id: "s1", limit: 2)
    service.fetch_page(stream_id: "s1", after: first[:next_after], limit: 2)
    assert_nil service.sync_state[:fetched_at], "a partial walk must never become the authoritative result"

    travel(Hcb::OrganizationTransactions::STREAM_HEARTBEAT_TIMEOUT + 1.second) do
      assert_equal :resumed, service.resume_stream!("s1")
    end

    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
    assert_nil service.stream_claim
  end

  test "a resumed walk picks up from the buffer rather than re-walking what the tab already fetched" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    first = service.fetch_page(stream_id: "s1", limit: 2)
    service.fetch_page(stream_id: "s1", after: first[:next_after], limit: 2)

    # Four of the six are already buffered, so finishing should cost the pages
    # covering the remaining two -- not a fresh walk of all six.
    calls_before = client.transactions_calls
    travel(Hcb::OrganizationTransactions::STREAM_HEARTBEAT_TIMEOUT + 1.second) do
      service.resume_stream!("s1")
    end

    assert_operator client.transactions_calls - calls_before, :<=, 2
  end

  test "abandon_stream! lets the walk be taken over without waiting out the heartbeat" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: transactions), "org_1")

    service.fetch_page(stream_id: "s1", limit: 2)
    # Without the handoff the claim is fresh, so nothing may touch it yet.
    assert_equal :running, service.resume_stream!("s1")

    assert service.abandon_stream!("s1")
    assert_equal :resumed, service.resume_stream!("s1")
    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
  end

  test "abandon_stream! ignores a beacon from a stream that no longer holds the claim" do
    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: []), "org_1")

    service.claim_stream!("owner", kind: :cold)
    assert_not service.abandon_stream!("someone-else")
    assert_equal :running, service.resume_stream!("owner")
  end

  test "a page restored from the bfcache after handing off does not walk beside the job" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    first = service.fetch_page(stream_id: "s1", limit: 2)
    service.abandon_stream!("s1")

    # The tab comes back and resumes its fetch loop where it left off.
    calls_before = client.transactions_calls
    resumed = service.fetch_page(stream_id: "s1", after: first[:next_after], limit: 2)

    assert resumed[:waiting], "a stream that has handed off must not keep fetching"
    assert_equal calls_before, client.transactions_calls
  end

  test "a cold stream does not make the organization look mid-reload" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: transactions), "org_1")

    service.fetch_page(stream_id: "s1", limit: 2)

    # #all returns [] for a reload because the caches have been purged; a cold
    # walk purges nothing, so the read paths must not treat it the same way.
    assert_not service.full_reload_running?
    assert service.drain_running?
    assert_not service.sync_state[:reloading]
    assert_equal :cold, service.sync_state[:drain_kind]
  end

  test "a walk taken over by a job owns the claim, so the tab it was taken from cannot walk alongside it" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    first = service.fetch_page(stream_id: "s1", limit: 2)
    service.abandon_stream!("s1")

    # Mid-takeover: the job holds the claim, and the tab that comes back must be
    # told to wait rather than fetch the same pages a second time.
    claim_during_takeover = nil
    service.stub(:drain, ->(**_kwargs) {
      claim_during_takeover = Hcb::OrganizationTransactions.new(client, "org_1").stream_claim
      []
    }) do
      service.resume_stream!("s1")
    end

    assert_not_equal "s1", claim_during_takeover[:stream_id]
    assert_equal :cold, claim_during_takeover[:kind]
  end

  test "sync_head! waits for a walk already building the history instead of queueing a second one" do
    transactions = (1..250).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    # A cold walk is under way, so there is nothing cached to peek against.
    service.fetch_page(stream_id: "s1", limit: 100)

    calls_before = client.transactions_calls
    assert_equal :draining, Hcb::OrganizationTransactions.new(client, "org_1").sync_head!
    assert_equal calls_before, client.transactions_calls, "the peek itself must not be spent either"
  end

  test "no background redrain is queued on top of a walk that is already running" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..250).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions, user_id: user.id)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    service.all
    travel(Hcb::OrganizationTransactions::BACKGROUND_REFRESH_INTERVAL + 1.second) do
      service.claim_stream!("someone-elses-walk", kind: :cold)
      assert_no_enqueued_jobs do
        Hcb::OrganizationTransactions.new(client, "org_1").all
      end
    end
  end

  # --- closing the tab and coming back ---------------------------------------

  test "reopening an organization continues the abandoned walk instead of starting a second one" do
    transactions = (1..500).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    # A tab opens a cold organization, gets two pages in, and is closed.
    first = service.fetch_page(stream_id: "tab-a", limit: 100)
    service.fetch_page(stream_id: "tab-a", after: first[:next_after], limit: 100)
    service.abandon_stream!("tab-a")
    spent_by_first_tab = client.transactions_calls

    # The organization is opened again.
    reopened = Hcb::OrganizationTransactions.new(client, "org_1")
    resumed = reopened.fetch_page(stream_id: "tab-b", limit: 100)

    # It picks the walk up rather than starting it: the 200 rows the first tab
    # had already fetched come straight back, and only the pages that were
    # actually still outstanding are bought from HCB.
    assert resumed[:resumed]
    assert_equal 300, resumed[:data].size, "the rows the closed tab had already fetched should come back with the first page"
    assert_equal transactions.first(300).map { |t| t["id"] }, resumed[:data].map { |t| t["id"] }
    assert_equal 1, client.transactions_calls - spent_by_first_tab

    # And finishing it costs only what is left, not another 500 rows.
    after = resumed
    after = reopened.fetch_page(stream_id: "tab-b", after: after[:next_after], limit: 100) while after[:has_more]

    assert_equal 5, client.transactions_calls, "the history should have been walked once between the two tabs, not twice"
    assert_equal transactions.map { |t| t["id"] }, reopened.all.map { |t| t["id"] }
  end

  test "the authoritative read never walks the history beside a walk already claimed" do
    transactions = (1..500).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    first = service.fetch_page(stream_id: "tab-a", limit: 100)
    service.fetch_page(stream_id: "tab-a", after: first[:next_after], limit: 100)
    spent = client.transactions_calls

    # /api/transactions -> OrganizationLedger#effective_cutoff -> #all, while
    # the walk above is still live. This is the path that used to start a
    # second full drain inline.
    assert_empty Hcb::OrganizationTransactions.new(client, "org_1").all
    assert_equal spent, client.transactions_calls
  end

  test "an authoritative read finishes an abandoned walk rather than being stranded by its claim" do
    transactions = (1..500).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    first = service.fetch_page(stream_id: "tab-a", limit: 100)
    service.fetch_page(stream_id: "tab-a", after: first[:next_after], limit: 100)
    service.abandon_stream!("tab-a")
    spent = client.transactions_calls

    # Nothing is advancing the claim, and no job got to it. Refusing outright
    # would leave the organization unreadable until the claim expired.
    result = Hcb::OrganizationTransactions.new(client, "org_1").all

    assert_equal transactions.map { |t| t["id"] }, result.map { |t| t["id"] }
    assert_equal 3, client.transactions_calls - spent, "it should finish the walk, not restart it"
  end

  # --- progress ---------------------------------------------------------------

  test "a streamed walk reports how far it has got while it is still running" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: transactions), "org_1")

    first = service.fetch_page(stream_id: "s1", limit: 2)
    mid = service.sync_state[:progress]

    assert_equal "cold", mid[:kind]
    assert_equal "browser", mid[:source]
    assert_equal 2, mid[:transactions_done]
    assert_equal 6, mid[:total_count]
    assert_not mid[:stalled]

    service.fetch_page(stream_id: "s1", after: first[:next_after], limit: 2)
    assert_equal 4, service.sync_state[:progress][:transactions_done]
  end

  test "progress reports done once the result is published" do
    service = Hcb::OrganizationTransactions.new(
      FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ]), "org_1"
    )
    service.fetch_page(stream_id: "s1", limit: 2)

    progress = service.sync_state[:progress]
    assert_equal "done", progress[:phase]
    assert_equal 1, progress[:transactions_done]
  end

  test "progress reports a walk nobody is advancing any more as stalled" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: transactions), "org_1")

    service.fetch_page(stream_id: "s1", limit: 2)
    assert_not service.sync_state[:progress][:stalled]

    travel(Hcb::DrainProgress::STALE_AFTER + 1.second) do
      assert service.sync_state[:progress][:stalled],
        "a drain nothing has advanced for longer than the stale window is not still running"
    end
  end

  test "a background job that takes a walk over reports itself as the one driving it" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: transactions), "org_1")

    service.fetch_page(stream_id: "s1", limit: 2)
    assert_equal "browser", service.sync_state[:progress][:source]

    service.abandon_stream!("s1")
    service.resume_stream!("s1")

    assert_equal "background", service.sync_state[:progress][:source]
  end

  test "sync_state names the drain its caches belong to, and a new drain renames it" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    token = service.sync_state[:token]
    assert token.present?
    assert_equal token, Hcb::OrganizationTransactions.new(client, "org_1").drain_token

    client.add_transactions([ { "id" => "txn_2", "date" => "2026-01-02", "amount_cents" => 2 } ])
    travel(1.minute) do
      fresh = Hcb::OrganizationTransactions.new(client, "org_1")
      fresh.sync_head!
      assert_not_equal token, fresh.sync_state[:token],
        "a browser holding rows for the old token must not be able to mistake them for current"
    end
  end

  test "a drain publishes the rendered rows and the ledger's display order alongside it" do
    client = FakeHcbClient.new(transactions: [
      { "id" => "txn_late", "date" => "2026-01-09", "memo" => "Sent early, settled late", "amount_cents" => -1_000,
        "ach_transfer" => { "created_at" => "2026-01-02T10:00:00Z" } },
      { "id" => "txn_declined", "date" => "2026-01-05", "memo" => "Declined", "amount_cents" => -7_500, "declined" => true },
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    service.all

    row = JSON.parse(service.presented["txn_1"])
    assert_equal Hcb::TransactionPresenter.new(client.transactions("org_1")["data"].last).as_json.as_json, row
    # Declined transactions are part of this cache: the ledger view lists them,
    # and a match can reference one.
    assert_equal %w[txn_1 txn_declined txn_late], service.presented.keys.sort

    order = service.ledger_order
    # By the date the ledger displays -- when it was sent -- not HCB's settled
    # date, which would have put txn_late last.
    assert_equal %w[txn_1 txn_late txn_declined], order[:ids]
    assert_equal [ 5_000, -1_000, -7_500 ], order[:amounts_cents]
    assert_equal [ false, false, true ], order[:declined]
  end

  test "side caches answer from the process-local memo without re-reading the store" do
    client = FakeHcbClient.new(transactions: [
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])
    Hcb::OrganizationTransactions.new(client, "org_1").all

    # Everything but the freshness stamp goes away, so anything still answered
    # can only have come from the copy the drain left in this process.
    Rails.cache.delete_matched(/transactions:v2(?!.*fetched)/)

    service = Hcb::OrganizationTransactions.new(client, "org_1")
    assert_equal "txn_1", service.find("txn_1")["id"]
    assert_equal %w[txn_1], service.derived[:ids]
    assert_equal %w[txn_1], service.presented.keys
    assert_equal %w[txn_1], service.ledger_order[:ids]
  end

  test "a drain elsewhere invalidates this process's copy rather than being served stale" do
    client = FakeHcbClient.new(transactions: [
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])
    Hcb::OrganizationTransactions.new(client, "org_1").all

    # Stands in for another process (a warming job, another web worker)
    # publishing a fresh drain into the shared store.
    client.add_transactions([ { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -5_000 } ])
    Hcb::OrganizationTransactions.new(client, "org_1").refresh!

    service = Hcb::OrganizationTransactions.new(client, "org_1")
    assert_equal %w[txn_2 txn_1], service.all.map { |t| t["id"] }
    assert_equal %w[txn_1 txn_2], service.presented.keys.sort
    assert_equal %w[txn_1 txn_2], service.ledger_order[:ids]
  end
end
