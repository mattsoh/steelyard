require "test_helper"

class Api::TransactionsControllerTest < ActionController::TestCase
  include ActiveJob::TestHelper

  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    session[:user_id] = @user.id
    # The refresh/sync_status endpoints are all cache reads and writes, which the
    # test environment's :null_store would silently swallow.
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    Rails.cache = @previous_cache
  end

  # Drains the organization the way the background task would have by the time
  # the authoritative endpoints are asked for it. #index no longer walks HCB
  # inside the request -- a cold organization is answered with the task
  # building it -- so tests of what #index *renders* start warm.
  def warm!(fake_client)
    Hcb::OrganizationTransactions.new(fake_client, "org_1").all
  end

  test "returns windowed transactions plus any older ones referenced by an active match" do
    windowed = { "id" => "txn_recent", "date" => "2026-06-01", "memo" => "Recent donation", "amount_cents" => 5_000 }
    aged_out = { "id" => "txn_old", "date" => "2020-01-01", "memo" => "Old grant", "amount_cents" => -5_000 }
    fake_client = FakeHcbClient.new(transactions: [ windowed ]) # aged_out is NOT in the cached window
    fake_client.define_singleton_method(:transaction) { |id| id == "txn_old" ? aged_out : nil }

    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_old", direction: :outgoing)
    warm!(fake_client)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    ids = JSON.parse(response.body)["transactions"].map { |t| t["id"] }
    assert_includes ids, "txn_recent"
    assert_includes ids, "txn_old"
  end

  test "zero_balance_options always offers the beginning of history" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])
    warm!(fake_client)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    options = JSON.parse(response.body)["zero_balance_options"]
    beginning = options.find { |o| o["transaction_id"] == OrganizationLedger::BEGINNING_ID }
    assert beginning
    assert_equal true, beginning["beginning"]
  end

  test "page answers a warm organization with every row, pre-serialized, and the drain token" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -5_000 },
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])
    Hcb::OrganizationTransactions.new(fake_client, "org_1").all
    calls_before = fake_client.transactions_calls

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        assert_no_enqueued_jobs do
          get :page, params: { organization_id: "org_1" }
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["warm"]
    assert_equal [ "txn_2", "txn_1" ], body["rows"].map { |t| t["id"] }
    assert_equal "Grant", body["rows"].first["memo"]
    assert body["token"].present?
    assert_equal "done", body.dig("progress", "phase")
    assert_equal calls_before, fake_client.transactions_calls
  end

  test "page on a cold organization starts one background task and answers with it, not with a walk" do
    transactions = (1..250).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        assert_enqueued_with(job: WarmOrganizationTransactionsJob) do
          get :page, params: { organization_id: "org_1" }
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["warm"]
    assert_empty body["rows"]
    assert_equal 0, body["pages_done"]
    assert_equal "starting", body.dig("progress", "phase")
    assert_equal "cold", body.dig("progress", "kind")
    assert body.dig("progress", "task_id").present?
    assert_equal 0, fake_client.transactions_calls, "the request itself must not walk HCB"
    assert_match(/started loading/, body["log"].first["text"])
  end

  test "page hands a viewer that joins mid-walk every page fetched so far, then only what is new" do
    transactions = (1..500).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")

    # A task somebody else started is three pages in.
    service.start_task!(kind: :cold, requested_by: "someone else")
    3.times do |i|
      Rails.cache.write(service.send(:page_key, i + 1), transactions[i * 100, 100], expires_in: 1.minute)
    end
    service.progress.advance!(pages_done: 3, transactions_done: 300, total_count: 500)
    calls_before = fake_client.transactions_calls

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        assert_no_enqueued_jobs do
          get :page, params: { organization_id: "org_1" }
        end
        first = JSON.parse(response.body)
        assert_equal 300, first["rows"].size, "a late joiner is handed everything fetched so far"
        assert_equal transactions.first(300).map { |t| t["id"] }, first["rows"].map { |t| t["id"] }
        assert_equal 3, first["pages_done"]
        assert_equal "someone else", first.dig("progress", "requested_by")

        # The task fetches one more page; the viewer asks for what's after the three it has.
        Rails.cache.write(service.send(:page_key, 4), transactions[300, 100], expires_in: 1.minute)
        service.progress.advance!(pages_done: 4, transactions_done: 400, total_count: 500)

        get :page, params: { organization_id: "org_1", after_page: first["pages_done"] }
        more = JSON.parse(response.body)
        assert_equal 100, more["rows"].size
        assert_equal "txn_200", more["rows"].first["id"]
        assert_equal 4, more["pages_done"]
      end
    end

    assert_equal calls_before, fake_client.transactions_calls, "watching a task must never cost an HCB request"
  end

  test "page only sends the activity-log lines after the seq the viewer has" do
    fake_client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")
    service.activity.append("first")
    service.activity.append("second")

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :page, params: { organization_id: "org_1", log_after: 1 }
      end
    end

    texts = JSON.parse(response.body)["log"].map { |e| e["text"] }
    assert_not_includes texts, "first"
    assert_includes texts, "second"
  end

  test "sync_status reports a task in flight, with its log, so a second tab can watch it instead of starting one" do
    transactions = (1..250).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :page, params: { organization_id: "org_1" }
        calls_before = fake_client.transactions_calls
        get :sync_status, params: { organization_id: "org_1" }

        assert_equal calls_before, fake_client.transactions_calls, "polling progress must never cost an HCB request"
      end
    end

    body = JSON.parse(response.body)
    assert body["draining"]
    assert_equal "cold", body["drain_kind"]
    assert_equal "cold", body.dig("progress", "kind")
    assert_equal "background", body.dig("progress", "source")
    assert_equal 250, body.dig("progress", "total_count").to_i if body.dig("progress", "total_count")
    assert_equal 1, body["log"].size
  end

  test "a failed load is reported as such and not restarted by the next poll" do
    fake_client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")
    task_id = service.start_task!(kind: :cold, requested_by: "a")
    service.progress.fail!("HCB is down")
    service.release_task!

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        assert_no_enqueued_jobs do
          get :page, params: { organization_id: "org_1" }
        end
        body = JSON.parse(response.body)
        assert_equal "failed", body.dig("progress", "phase")
        assert_equal task_id, body.dig("progress", "task_id")

        # The explicit retry starts a fresh task.
        assert_enqueued_with(job: WarmOrganizationTransactionsJob) do
          get :page, params: { organization_id: "org_1", retry: "1" }
        end
        assert_equal "starting", JSON.parse(response.body).dig("progress", "phase")
      end
    end
  end

  test "the authoritative view starts the task and says it is loading rather than reporting an empty organization" do
    transactions = (1..500).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        assert_enqueued_with(job: WarmOrganizationTransactionsJob) do
          get :index, params: { organization_id: "org_1" }
        end
        body = JSON.parse(response.body)

        assert_empty body["transactions"]
        assert body["draining"], "an empty result mid-walk must be distinguishable from an empty organization"
        assert_not body["reloading"], "a first load is not a reload"
        assert_equal 0, fake_client.transactions_calls,
          "the authoritative read must not walk the history inside the request"
      end
    end
  end

  test "refresh reports fresh, and enqueues nothing, when HCB has nothing new" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])
    Hcb::OrganizationTransactions.new(fake_client, "org_1").all

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
          post :refresh, params: { organization_id: "org_1" }
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "fresh", body["status"]
    assert_equal 1, body["count"]
  end

  test "refresh syncs a newly-landed transaction inline so the next index read sees it" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])
    Hcb::OrganizationTransactions.new(fake_client, "org_1").all
    fake_client.add_transactions([ { "id" => "txn_2", "date" => "2026-01-02", "memo" => "New grant", "amount_cents" => -5_000 } ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :refresh, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "synced", body["status"]
    assert_equal 2, body["count"]
    assert_equal [ "txn_2", "txn_1" ], Hcb::OrganizationTransactions.new(fake_client, "org_1").all.map { |t| t["id"] }
  end

  test "refresh hands a too-deep sync to the background job instead of doing it inline" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        assert_enqueued_with(job: WarmOrganizationTransactionsJob) do
          post :refresh, params: { organization_id: "org_1" }
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "deep", body["status"]
    assert body["draining"], "the redrain is a task every viewer can now watch"
    assert_equal "cold", body.dig("progress", "kind")
  end

  test "refresh records what it found in the log everyone reads" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])
    Hcb::OrganizationTransactions.new(fake_client, "org_1").all
    @user.update!(name: "Matthew")

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :refresh, params: { organization_id: "org_1" }
      end
    end

    log = JSON.parse(response.body)["log"]
    assert_match(/Matthew checked HCB.*up to date/, log.last["text"])
  end

  test "sync_status reports the current drain stamp without touching HCB" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])
    Hcb::OrganizationTransactions.new(fake_client, "org_1").all
    calls_before = fake_client.transactions_calls

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :sync_status, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["count"]
    assert body["fetched_at"]
    assert_equal calls_before, fake_client.transactions_calls
  end

  test "reload starts one background task and queues the job that runs it" do
    fake_client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        assert_enqueued_with(job: WarmOrganizationTransactionsJob) do
          post :reload, params: { organization_id: "org_1" }
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "started", body["status"]
    assert body["task_id"].present?
    assert body["reloading"]
    assert_equal "reload", body.dig("progress", "kind")
    assert_equal 0, fake_client.transactions_calls, "the walk is the job's, not the request's"
  end

  test "a second tab asking for a reload is told one is already running, and watches that one" do
    fake_client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :reload, params: { organization_id: "org_1" }
        first = JSON.parse(response.body)
        assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
          post :reload, params: { organization_id: "org_1" }
        end
        body = JSON.parse(response.body)
        assert_equal "already_running", body["status"]
        assert_nil body["task_id"]
        assert_equal first["task_id"], body.dig("progress", "task_id")
      end
    end
  end

  test "every viewer sees a reload's pages as they land, not just the tab that asked" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :reload, params: { organization_id: "org_1" }

        # The job has fetched the first page of the reload.
        Rails.cache.write(service.send(:page_key, 1), transactions[0, 2], expires_in: 1.minute)
        service.progress.advance!(pages_done: 1, transactions_done: 2, total_count: 3)

        get :page, params: { organization_id: "org_1" }
      end
    end

    body = JSON.parse(response.body)
    assert_not body["warm"]
    assert_equal %w[txn_3 txn_2], body["rows"].map { |t| t["id"] }
    assert_equal "reload", body.dig("progress", "kind")
  end

  test "reload clears the organization's caches before the walk starts, not after it finishes" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)

    warm!(fake_client)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :reload, params: { organization_id: "org_1" }
      end
    end

    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")
    # Nothing of the previous drain is left to answer another request from --
    # the point of a full reload being a clean slate rather than an overwrite.
    assert_nil service.sync_state[:fetched_at]
    assert_nil service.find("txn_1")
    assert_nil service.presented
    assert service.sync_state[:reloading]
    # But the task's own record survives the purge: it is what every viewer is
    # about to watch.
    assert_equal "reload", service.progress.read[:kind]
  end

  test "index says it is reloading rather than reporting an organization with no transactions" do
    fake_client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :reload, params: { organization_id: "org_1" }
        get :index, params: { organization_id: "org_1" }
      end
    end

    body = JSON.parse(response.body)
    assert body["reloading"]
    assert_empty body["transactions"]
  end

  test "refresh queues nothing while a full reload is already rebuilding the history" do
    fake_client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :reload, params: { organization_id: "org_1" }
        # An incremental redrain queued here would splice the baseline the
        # reload just dropped, and publish a fetched_at the reloading tab reads
        # as its own drain having landed.
        assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
          post :refresh, params: { organization_id: "org_1" }
        end
      end
    end

    assert_equal "reloading", JSON.parse(response.body)["status"]
  end

  test "an ordinary load during a reload attaches to the reload instead of walking the history alongside it" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :reload, params: { organization_id: "org_1" }
        task_id = JSON.parse(response.body)["task_id"]
        calls_before = fake_client.transactions_calls
        assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
          get :page, params: { organization_id: "org_1" }
        end
        assert_equal calls_before, fake_client.transactions_calls
        body = JSON.parse(response.body)
        assert_not body["warm"]
        assert_equal task_id, body.dig("progress", "task_id")
      end
    end
  end

  test "a full reload rebuilds the history and the matches are re-derived against what came back" do
    incoming = { "id" => "txn_in", "date" => "2026-01-01", "amount_cents" => 10_000 }
    outgoing = { "id" => "txn_out", "date" => "2026-01-02", "amount_cents" => -10_000 }
    fake_client = FakeHcbClient.new(transactions: [ outgoing, incoming ])

    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)
    warm!(fake_client)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        # Between the two loads HCB re-groups one leg away and restates the
        # other -- exactly what a full reload exists to discover.
        fake_client.remove_transaction("txn_out")
        fake_client.update_transaction("txn_in", "amount_cents" => 12_500)

        post :reload, params: { organization_id: "org_1" }
        task_id = JSON.parse(response.body)["task_id"]
        # The purge means nothing of the previous drain is left to resync
        # against, which is why the matches are only re-derived once the fresh
        # walk has landed -- not during it. The job runs the task.
        Hcb::OrganizationTransactions.new(fake_client, "org_1").run_task!(task_id)
      end
    end

    # Matches are re-derived when they're read, against whatever the reload
    # published -- so this is the composition being checked: purge, fresh walk,
    # then the matches judged against what came back rather than what was
    # cached before.
    resync = Matches::Resync.new(
      ledger: OrganizationLedger.new(fake_client, "org_1"),
      matches: Match.active.for_organization("org_1").includes(:match_transactions, :adjustments)
    ).call

    dropped = resync.dropped.sole
    assert_equal [ "txn_out" ], dropped.transaction_ids
    assert_equal [ "txn_in" ], match.reload.match_transactions.active.map(&:hcb_transaction_id)
    # Off by the reloaded amount of the leg that survived, not the one it was
    # confirmed against.
    assert_equal 12_500, match.discrepancy_cents
  end

  test "a page reports how much of it went to HCB" do
    fake_client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :page, params: { organization_id: "org_1" }
      end
    end

    # The activity log reads this to say whether a slow load is us or HCB, which
    # is guesswork from the outside otherwise. A page never walks HCB itself
    # now, so the honest answer is zero.
    hcb = JSON.parse(response.body)["hcb"]
    assert_equal 0, hcb["requests"]
    assert hcb.key?("ms")
    assert hcb.key?("slowest_ms")
  end

  test "index reports the organization's balance the way HCB works it out" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_pending_in", "date" => "2026-03-01", "amount_cents" => 50_000, "pending" => true },
      { "id" => "txn_pending_out", "date" => "2026-02-01", "amount_cents" => -2_500, "pending" => true },
      { "id" => "txn_settled_in", "date" => "2026-01-01", "amount_cents" => 10_000 }
    ])
    warm!(fake_client)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") { get :index, params: { organization_id: "org_1" } }
    end

    body = JSON.parse(response.body)
    # Settled plus pending outgoing; the pending deposit isn't counted.
    assert_equal 75.0, body["balance"]
    # And it's kept off the working set too, so nobody tries to reconcile money
    # that hasn't arrived.
    assert_not_includes body["transactions"].map { |t| t["id"] }, "txn_pending_in"
    assert_includes body["transactions"].map { |t| t["id"] }, "txn_pending_out"
  end

  test "a pending incoming transaction is never streamed into the ledger's order" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_pending_in", "date" => "2026-03-01", "amount_cents" => 50_000, "pending" => true },
      { "id" => "txn_settled_in", "date" => "2026-01-01", "amount_cents" => 10_000 }
    ])

    warm!(fake_client)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
      end
    end

    ledger = Hcb::OrganizationTransactions.new(fake_client, "org_1")
    assert_equal [ "txn_settled_in" ], ledger.ledger_order[:ids]
    # Still presentable, because a match leg can point at it.
    assert ledger.presented["txn_pending_in"]
  end
end
