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

  test "a cold task walks the history page by page, keeping each page where a viewer can read it" do
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    task_id = service.start_task!(kind: :cold, requested_by: "Matthew")
    assert task_id.present?
    assert service.drain_running?
    assert_equal "starting", service.progress.read[:phase]

    # Mid-walk, the pages fetched so far are readable by anyone -- a tab that
    # joins late gets everything up to now in one go, then asks for what's new.
    seen = []
    service.stub(:page, ->(after: nil, limit:) {
      result = client.transactions("org_1", after: after, limit: 2)
      seen << service.task_pages(0).size
      result
    }) do
      result = service.run_task!(task_id)
      assert_equal transactions.map { |t| t["id"] }, result.map { |t| t["id"] }
    end
    # Before pages 1, 2 and 3 were fetched the buffer held 0, 2 and 4 rows.
    assert_equal [ 0, 2, 4 ], seen

    # Published to the same cache #all reads from, the claim released, and the
    # per-page buffer gone with it.
    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
    assert_nil service.task_claim
    assert_not service.drain_running?
    assert_equal "done", service.progress.read[:phase]
    assert_empty service.task_pages(0)
  end

  test "task_pages answers from the page a viewer already has onwards" do
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    task_id = service.start_task!(kind: :cold, requested_by: "Matthew")

    # The task has fetched two pages of two.
    Rails.cache.write(service.send(:page_key, 1), transactions[0, 2], expires_in: Hcb::OrganizationTransactions::TASK_PAGE_TTL)
    Rails.cache.write(service.send(:page_key, 2), transactions[2, 2], expires_in: Hcb::OrganizationTransactions::TASK_PAGE_TTL)
    service.progress.advance!(pages_done: 2, transactions_done: 4, total_count: 5)

    assert_equal %w[txn_5 txn_4 txn_3 txn_2], service.task_pages(0).map { |t| t["id"] }
    assert_equal %w[txn_3 txn_2], service.task_pages(1).map { |t| t["id"] }
    assert_empty service.task_pages(2)
  end

  test "an incremental task keeps no pages: its result is a splice that only exists once it has finished" do
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    client.add_transactions([ { "id" => "txn_6", "date" => "2026-01-02", "amount_cents" => 6 } ])
    task_id = service.start_task!(kind: :incremental, requested_by: "Matthew")
    assert_empty service.task_pages(0)
    assert_equal :incremental, service.task_claim[:kind]

    result = service.run_task!(task_id)
    assert_equal "txn_6", result.first["id"]
    assert_equal 6, service.all.size
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

  test "a load after the primary cache has expired is an incremental task, not a full re-walk" do
    old_transactions = (1..500).map { |n| { "id" => "txn_old_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: old_transactions, user_id: 7)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    service.all

    new_transactions = [ { "id" => "txn_new_1", "date" => "2026-02-01", "amount_cents" => 1 } ]
    client.add_transactions(new_transactions)

    travel(Hcb::OrganizationTransactions::TTL + 1.second) do
      task = nil
      assert_enqueued_with(job: WarmOrganizationTransactionsJob) do
        task = service.ensure_loaded!(requested_by: "Matthew", user_id: 7)
      end
      assert_equal "incremental", task[:kind]
      assert_equal 500, task[:total_count], "the baseline's size is the denominator a viewer sees"

      calls_before = client.transactions_calls
      result = service.run_task!(task[:task_id])
      calls_during = client.transactions_calls - calls_before

      assert_equal 501, result.size
      assert_equal "txn_new_1", result.first["id"]
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
    stamp_before = service.sync_state.except(:progress, :log)

    travel(1.minute) do
      assert_equal :fresh, Hcb::OrganizationTransactions.new(client, "org_1").sync_head!
      after = Hcb::OrganizationTransactions.new(client, "org_1").sync_state
      assert_equal stamp_before, after.except(:progress, :log)
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
      { fetched_at: nil, count: nil, token: nil, reloading: false, draining: false, drain_kind: nil, progress: nil, log: [] },
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

  # --- one task per organization -----------------------------------------------

  test "a claimed reload stops every other path from draining the same history again" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    assert service.start_task!(kind: :reload, requested_by: "Matthew", resume: false)
    service.purge!

    calls_before = client.transactions_calls
    other = Hcb::OrganizationTransactions.new(client, "org_1")

    # Nothing cached and no baseline, so without the claim check each of these
    # would start its own full walk of the org's history -- exactly the
    # duplicate rate-limit spend the claim exists to prevent.
    assert_empty other.all
    assert_equal :reloading, other.sync_head!
    assert_nil other.start_task!(kind: :cold, requested_by: "someone else")
    assert_equal other.progress.read[:task_id], other.ensure_loaded!(requested_by: "someone else", user_id: 1)[:task_id]

    assert_equal calls_before, client.transactions_calls
    assert other.sync_state[:reloading]
    assert other.full_reload_running?
  end

  test "a claimed task stops the background refresh being queued on top of it" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ], user_id: 7)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.start_task!(kind: :reload, requested_by: "Matthew", resume: false)
    service.purge!

    # A purged cache reads as maximally stale, so without the check this would
    # queue a redrain on every request for the whole duration of the reload.
    assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
      Hcb::OrganizationTransactions.new(client, "org_1").all
    end
  end

  test "a reload task re-walks history from HCB and publishes only once its last page lands" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all # cache and baseline both warm now

    task_id = service.start_task!(kind: :reload, requested_by: "Matthew", resume: false)
    service.purge!
    calls_before = client.transactions_calls

    stamps = []
    service.stub(:page, ->(after: nil, limit:) {
      stamps << service.sync_state[:fetched_at]
      client.transactions("org_1", after: after, limit: 1)
    }) do
      service.run_task!(task_id)
    end

    # The whole point of a full reload is not trusting what's cached: every
    # page actually requested, and a partial walk never published -- a drain
    # missing its older half is a wrong running balance for every row above it.
    assert_equal 3, client.transactions_calls - calls_before
    assert_equal [ nil, nil, nil ], stamps
    assert_equal 3, service.sync_state[:count]
    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
    # Released on the way out, so the next reload can be claimed.
    assert_nil service.task_claim
    assert_not service.full_reload_running?
  end

  test "a second request attaches to the task already running instead of buying a second copy of it" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ], user_id: 7)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    first = service.ensure_loaded!(requested_by: "a", user_id: 7)
    calls_before = client.transactions_calls

    # Two tabs opening the same cold organization used to each walk the whole
    # history, against a rate limit they share with everybody else.
    assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
      second = Hcb::OrganizationTransactions.new(client, "org_1").ensure_loaded!(requested_by: "b", user_id: 8)
      assert_equal first[:task_id], second[:task_id]
    end
    assert_equal calls_before, client.transactions_calls
  end

  test "ensure_loaded! is a no-op for a warm organization" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ], user_id: 7)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
      assert_nil service.ensure_loaded!(requested_by: "a", user_id: 7)
    end
    assert_nil service.task_claim
  end

  test "a task whose claim has moved on stops rather than publishing over the new owner" do
    transactions = (1..4).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    task_id = service.start_task!(kind: :cold, requested_by: "a")

    # After the first page, another task takes the claim (having judged this
    # one dead).
    fetched = 0
    service.stub(:page, ->(after: nil, limit:) {
      fetched += 1
      Rails.cache.write(service.send(:task_claim_key), { task_id: "takeover", kind: :cold }) if fetched == 1
      client.transactions("org_1", after: after, limit: 1)
    }) do
      assert_equal :superseded, service.run_task!(task_id)
    end

    assert_equal 1, fetched, "it must stop at the next claim check, not walk on"
    assert_nil service.sync_state[:fetched_at]
    # The claim is the other task's to release.
    assert_equal "takeover", service.task_claim[:task_id]
  end

  # --- a task that dies -------------------------------------------------------

  test "a stalled task is taken over and finished from the pages it had already fetched" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions, user_id: 7)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    # A task fetches two pages, then its worker dies: nothing advances it.
    task_id = service.start_task!(kind: :cold, requested_by: "a")
    Rails.cache.write(service.send(:page_key, 1), transactions[0, 2], expires_in: Hcb::OrganizationTransactions::TASK_PAGE_TTL)
    Rails.cache.write(service.send(:page_key, 2), transactions[2, 2], expires_in: Hcb::OrganizationTransactions::TASK_PAGE_TTL)
    service.progress.advance!(pages_done: 2, transactions_done: 4, total_count: 6)
    assert_nil service.sync_state[:fetched_at], "a partial walk must never become the authoritative result"

    travel(Hcb::DrainProgress::STALE_AFTER + 1.second) do
      assert service.stale_task?
      assert_not service.drain_running?
      assert service.sync_state[:progress][:stalled]

      # Nobody is advancing the claim. Refusing outright would leave the
      # organization unreadable until the claim expired; starting over would
      # re-buy the pages already fetched.
      taken = Hcb::OrganizationTransactions.new(client, "org_1").ensure_loaded!(requested_by: "b", user_id: 7)
      assert_not_equal task_id, taken[:task_id]
      assert_equal 2, service.task_claim[:resume_pages]

      calls_before = client.transactions_calls
      service.stub(:page, ->(after: nil, limit:) { client.transactions("org_1", after: after, limit: 2) }) do
        service.run_task!(taken[:task_id])
      end
      assert_equal 1, client.transactions_calls - calls_before, "it should finish the walk, not restart it"
    end

    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
    assert_nil service.task_claim
  end

  test "a live task is left alone" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.start_task!(kind: :cold, requested_by: "a")

    assert_not service.stale_task?
    assert_nil service.start_task!(kind: :cold, requested_by: "b")
    assert_equal :draining, service.sync_head!
  end

  test "a reload never resumes the pages of the task it replaces" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.start_task!(kind: :cold, requested_by: "a")
    Rails.cache.write(service.send(:page_key, 1), transactions[0, 2], expires_in: Hcb::OrganizationTransactions::TASK_PAGE_TTL)
    service.progress.advance!(pages_done: 1, transactions_done: 2)

    travel(Hcb::DrainProgress::STALE_AFTER + 1.second) do
      assert service.start_task!(kind: :reload, requested_by: "b", resume: false)
      # Re-reading those pages is the whole point of a reload.
      assert_equal 0, service.task_claim[:resume_pages]
    end
  end

  test "an inline read finishes a stalled task rather than being stranded by its claim" do
    transactions = (1..500).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.start_task!(kind: :cold, requested_by: "a")
    Rails.cache.write(service.send(:page_key, 1), transactions[0, 100], expires_in: Hcb::OrganizationTransactions::TASK_PAGE_TTL)
    Rails.cache.write(service.send(:page_key, 2), transactions[100, 100], expires_in: Hcb::OrganizationTransactions::TASK_PAGE_TTL)
    service.progress.advance!(pages_done: 2, transactions_done: 200, total_count: 500)
    spent = client.transactions_calls

    travel(Hcb::DrainProgress::STALE_AFTER + 1.second) do
      # /api/v1 -> OrganizationLedger -> #all, with nobody advancing the claim
      # and no job having got to it.
      result = Hcb::OrganizationTransactions.new(client, "org_1").all

      assert_equal transactions.map { |t| t["id"] }, result.map { |t| t["id"] }
      assert_equal 3, client.transactions_calls - spent, "it should finish the walk, not restart it"
    end
  end

  test "the authoritative read never walks the history beside a live task" do
    transactions = (1..500).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.start_task!(kind: :cold, requested_by: "a")
    spent = client.transactions_calls

    assert_empty Hcb::OrganizationTransactions.new(client, "org_1").all
    assert_equal spent, client.transactions_calls
  end

  # --- failure ----------------------------------------------------------------

  test "a failed task records why, releases the claim, and is not restarted by the next poll" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ], user_id: 7)
    client.define_singleton_method(:transactions) { |*, **| raise "HCB is down" }
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    task = service.ensure_loaded!(requested_by: "a", user_id: 7)
    assert_raises(RuntimeError) { service.run_task!(task[:task_id]) }

    record = service.progress.read
    assert_equal "failed", record[:phase]
    assert_equal "HCB is down", record[:error]
    assert_nil service.task_claim
    assert_includes service.activity.read.map { |e| e[:text] }.join("\n"), "HCB is down"

    # Every open tab polls while it waits; each poll restarting the task would
    # be a tight loop of failures against the shared rate limit.
    assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
      assert_equal task[:task_id], service.ensure_loaded!(requested_by: "b", user_id: 7)[:task_id]
    end

    # An explicit retry is different.
    assert_enqueued_with(job: WarmOrganizationTransactionsJob) do
      assert_not_equal task[:task_id], service.ensure_loaded!(requested_by: "b", user_id: 7, force: true)[:task_id]
    end
  end

  test "a retry after a failure carries on from the pages the failed walk fetched" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions, user_id: 7)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    task_id = service.start_task!(kind: :cold, requested_by: "a")
    fetched = 0
    service.stub(:page, ->(after: nil, limit:) {
      fetched += 1
      raise "HCB is down" if fetched == 3
      client.transactions("org_1", after: after, limit: 2)
    }) do
      assert_raises(RuntimeError) { service.run_task!(task_id) }
    end

    retried = service.ensure_loaded!(requested_by: "a", user_id: 7, force: true)
    assert_equal 2, service.task_claim[:resume_pages]
    calls_before = client.transactions_calls
    service.stub(:page, ->(after: nil, limit:) { client.transactions("org_1", after: after, limit: 2) }) do
      service.run_task!(retried[:task_id])
    end
    assert_equal 1, client.transactions_calls - calls_before
    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
  end

  # --- progress and the log ---------------------------------------------------

  test "a task reports how far it has got while it is still running" do
    transactions = (1..6).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    task_id = service.start_task!(kind: :cold, requested_by: "Matthew")

    seen = []
    service.stub(:page, ->(after: nil, limit:) {
      seen << service.sync_state[:progress].slice(:kind, :source, :requested_by, :transactions_done, :total_count, :stalled, :running)
      client.transactions("org_1", after: after, limit: 2)
    }) do
      service.run_task!(task_id)
    end

    assert_equal(
      { kind: "cold", source: "background", requested_by: "Matthew", transactions_done: 2, total_count: 6, stalled: false, running: true },
      seen[1]
    )
    assert_equal 4, seen[2][:transactions_done]
  end

  test "progress reports done once the result is published, and keeps saying so for a later viewer" do
    service = Hcb::OrganizationTransactions.new(
      FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ]), "org_1"
    )
    service.run_task!(service.start_task!(kind: :cold, requested_by: "a"))

    progress = service.sync_state[:progress]
    assert_equal "done", progress[:phase]
    assert_equal 1, progress[:transactions_done]
    assert_not progress[:running]

    travel(Hcb::DrainProgress::TTL + 1.minute) do
      assert_equal "done", service.sync_state[:progress][:phase], "the record of a finished task outlives a running one's TTL"
    end
  end

  test "the activity log records the walk for every viewer, and answers from a seq onwards" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    task_id = service.start_task!(kind: :cold, requested_by: "Matthew")
    started = service.activity.read
    assert_equal 1, started.size
    assert_match(/Matthew started loading/, started.first[:text])

    service.stub(:page, ->(after: nil, limit:) { client.transactions("org_1", after: after, limit: 2) }) do
      service.run_task!(task_id)
    end

    # A different instance -- another tab, another process -- reads the same
    # account, and only what it hasn't seen when it says where it got to.
    later = Hcb::OrganizationTransactions.new(client, "org_1").activity.read(after: started.last[:seq])
    assert_equal [ "hcb", "hcb", "info", "done" ], later.map { |e| e[:kind] }
    assert_match(/page 1: 2 transactions/, later[0][:text])
    assert_match(/page 2: 1 transactions/, later[1][:text])
    assert_match(/3 transactions published/, later.last[:text])
    assert later.all? { |e| e[:task_id] == task_id }
    assert_equal later, service.sync_state(log_after: started.last[:seq])[:log]
  end

  test "sync_head! writes what it found to the log" do
    client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 100 } ])
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    assert_equal :fresh, service.sync_head!(requested_by: "Matthew")
    client.add_transactions([ { "id" => "txn_2", "date" => "2026-01-02", "amount_cents" => 200 } ])
    assert_equal :synced, service.sync_head!(requested_by: "Matthew")

    texts = service.activity.read.map { |e| e[:text] }
    assert_match(/Matthew checked HCB.*already up to date/, texts[-2])
    assert_match(/Matthew checked HCB.*1 new transaction, spliced/, texts[-1])
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
  # HCB orders an organization's transactions by date and returns rows that
  # share a date in an order that shifts between requests, so a cursor page
  # can repeat the row its cursor sat on. Here every page after the first
  # hands back the cursor row again, the way HCB does at a shifted boundary.
  test "a drain publishes each transaction once when HCB's pages overlap" do
    transactions = (1..7).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    # Three to a page so the walk crosses two boundaries; each boundary row
    # then arrives twice, as the end of one page and the start of the next.
    overlapping = lambda do |after: nil, limit:|
      rows = after ? transactions.drop_while { |t| t["id"] != after } : transactions
      { "data" => rows.first(3), "has_more" => rows.size > 3, "total_count" => transactions.size }
    end

    task_id = service.start_task!(kind: :cold, requested_by: "Matthew")
    service.stub(:page, overlapping) { service.run_task!(task_id) }

    cached = Hcb::OrganizationTransactions.new(client, "org_1").all
    assert_equal transactions.map { |t| t["id"] }, cached.map { |t| t["id"] }
    assert_equal 7, service.sync_state[:count]
    assert_equal 7, service.progress.read[:total_count]

    texts = service.activity.read.map { |e| e[:text] }
    assert texts.any? { |t| t.match?(/returned \d+ transactions? more than once/) }, texts.inspect
    assert_match(/7 transactions published/, texts.last)
  end

  test "sync_head! keeps one copy of a transaction that moved into the newest page" do
    old_transactions = (1..500).map { |n| { "id" => "txn_old_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: old_transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")
    service.all

    # HCB now lists txn_old_300 at the head (its date moved, say), while the
    # cached tail being spliced on still has it at its old position.
    client.remove_transaction("txn_old_300")
    client.add_transactions([ { "id" => "txn_old_300", "date" => "2026-02-01", "amount_cents" => 300_00 } ])

    assert_equal :synced, service.sync_head!

    cached = Hcb::OrganizationTransactions.new(client, "org_1").all
    assert_equal 500, cached.size
    assert_equal 1, cached.count { |t| t["id"] == "txn_old_300" }
    # The freshly fetched copy, not the stale one from the tail.
    assert_equal "txn_old_300", cached.first["id"]
    assert_equal 300_00, cached.first["amount_cents"]
    assert_equal 500, service.sync_state[:count]
  end

  test "a drain says so when HCB's count shows rows fell between its pages" do
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    # HCB counts six; the pages only ever hand over five.
    short = ->(after: nil, limit:) { client.transactions("org_1", after: after, limit: limit).merge("total_count" => 6) }

    task_id = service.start_task!(kind: :cold, requested_by: "Matthew")
    service.stub(:page, short) { service.run_task!(task_id) }

    assert_equal 5, Hcb::OrganizationTransactions.new(client, "org_1").all.size
    warning = service.activity.read.find { |e| e[:kind] == "warn" }
    assert warning, service.activity.read.inspect
    assert_match(/has 6 transactions but 5 were published/, warning[:text])
    assert_equal task_id, warning[:task_id]
  end

  test "a drain whose count matches HCB's does not warn" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    task_id = service.start_task!(kind: :cold, requested_by: "Matthew")
    service.run_task!(task_id)

    assert_empty service.activity.read.select { |e| e[:kind] == "warn" }
  end
end
