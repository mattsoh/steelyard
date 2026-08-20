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

  test "returns windowed transactions plus any older ones referenced by an active match" do
    windowed = { "id" => "txn_recent", "date" => "2026-06-01", "memo" => "Recent donation", "amount_cents" => 5_000 }
    aged_out = { "id" => "txn_old", "date" => "2020-01-01", "memo" => "Old grant", "amount_cents" => -5_000 }
    fake_client = FakeHcbClient.new(transactions: [ windowed ]) # aged_out is NOT in the cached window
    fake_client.define_singleton_method(:transaction) { |id| id == "txn_old" ? aged_out : nil }

    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_old", direction: :outgoing)

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

  test "page returns presented transactions for a stream_id, with no more pages left" do
    fake_client = FakeHcbClient.new(transactions: [
      { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -5_000 },
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 5_000 }
    ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :page, params: { organization_id: "org_1", stream_id: "s1" }
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ "txn_2", "txn_1" ], body["rows"].map { |t| t["id"] }
    assert_not body["has_more"]
    assert_nil body["next_after"]
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
        assert_enqueued_with(job: WarmOrganizationTransactionsJob, args: [ @user.id, "org_1" ]) do
          post :refresh, params: { organization_id: "org_1" }
        end
      end
    end

    assert_response :success
    assert_equal "deep", JSON.parse(response.body)["status"]
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

  test "reload hands the winning tab a stream to drive, and queues the job behind it" do
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
    # The stream_id is what lets the tab ask for reload-mode pages and render
    # the walk as it arrives instead of polling a cleared page.
    assert body["stream_id"].present?
  end

  test "a second tab asking for a reload gets no stream and waits for the one already running" do
    fake_client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :reload, params: { organization_id: "org_1" }
        post :reload, params: { organization_id: "org_1" }
      end
    end

    body = JSON.parse(response.body)
    assert_equal "already_running", body["status"]
    assert_nil body["stream_id"]
  end

  test "a reload-mode page from a stream that doesn't hold the claim is refused" do
    fake_client = FakeHcbClient.new(transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "amount_cents" => 1 } ])

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :reload, params: { organization_id: "org_1" }
        # Without this check, a full re-walk of the org's entire history would
        # be something any caller could ask for at will.
        get :page, params: { organization_id: "org_1", stream_id: "not-the-winner", reload: "1" }
      end
    end

    assert_response :conflict
  end

  test "the tab holding the claim streams reload-mode pages" do
    transactions = (1..3).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        post :reload, params: { organization_id: "org_1" }
        stream_id = JSON.parse(response.body)["stream_id"]
        get :page, params: { organization_id: "org_1", stream_id: stream_id, reload: "1", limit: 1 }
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 3, body["rows"].size
    assert_not body["has_more"]
  end
end
