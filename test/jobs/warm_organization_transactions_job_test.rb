require "test_helper"

class WarmOrganizationTransactionsJobTest < ActiveJob::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "redrains and writes straight to the cache #all reads from" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    fake_client = FakeHcbClient.new(
      transactions: [ { "id" => "txn_1", "date" => "2026-01-01", "memo" => "A", "amount_cents" => 100 } ]
    )
    Hcb::Client.stub(:for_user, ->(u) { u == user ? fake_client : flunk("unexpected user") }) do
      WarmOrganizationTransactionsJob.perform_now(user.id, "org_1")
    end

    result = Hcb::OrganizationTransactions.new(fake_client, "org_1").all
    assert_equal [ "txn_1" ], result.map { |t| t["id"] }
    assert_equal 1, fake_client.transactions_calls
  end

  test "does nothing when the user no longer exists" do
    assert_nothing_raised { WarmOrganizationTransactionsJob.perform_now(-1, "org_1") }
  end

  test "runs the task a request claimed and handed to it" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..250).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions, user_id: user.id)
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")

    task = service.ensure_loaded!(requested_by: "Matthew", user_id: user.id)
    assert_equal "starting", task[:phase]

    Hcb::Client.stub(:for_user, ->(_u) { fake_client }) do
      perform_enqueued_jobs(only: WarmOrganizationTransactionsJob)
    end

    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
    assert_equal "done", service.progress.read[:phase]
    assert_equal task[:task_id], service.progress.read[:task_id]
    assert_nil service.task_claim
  end

  test "the periodic refresh claims a task of its own, and stands down if another is running" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")

    service.start_task!(kind: :cold, requested_by: "somebody")
    calls_before = fake_client.transactions_calls

    Hcb::Client.stub(:for_user, ->(_u) { fake_client }) do
      WarmOrganizationTransactionsJob.perform_now(user.id, "org_1")
    end

    # The live task is still the one drawing on the shared rate limit.
    assert_equal calls_before, fake_client.transactions_calls
    assert_nil service.sync_state[:fetched_at]
    assert_equal "somebody", service.progress.read[:requested_by]
  end

  test "a job for a task that has since been taken over does nothing" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")

    stale_task = service.start_task!(kind: :cold, requested_by: "a")
    travel(Hcb::DrainProgress::STALE_AFTER + 1.second) do
      service.start_task!(kind: :cold, requested_by: "b")
    end
    calls_before = fake_client.transactions_calls

    Hcb::Client.stub(:for_user, ->(_u) { fake_client }) do
      WarmOrganizationTransactionsJob.perform_now(user.id, "org_1", task_id: stale_task)
    end

    assert_equal calls_before, fake_client.transactions_calls
    assert service.drain_running?, "the new owner's claim must be left in place"
  end

  test "a failed task drops the claim rather than blocking the next attempt for its whole TTL" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)
    fake_client.define_singleton_method(:transactions) { |*, **| raise "HCB is down" }

    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: transactions), "org_1")
    task_id = service.start_task!(kind: :reload, requested_by: "a", resume: false)

    Hcb::Client.stub(:for_user, ->(_u) { fake_client }) do
      assert_raises(RuntimeError) do
        WarmOrganizationTransactionsJob.perform_now(user.id, "org_1", task_id: task_id)
      end
    end

    assert_nil service.task_claim
    assert_equal "failed", service.progress.read[:phase]
  end

  test "an expired token is recorded against the task rather than raised out of the job" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    fake_client = FakeHcbClient.new(transactions: [])
    fake_client.define_singleton_method(:transactions) { |*, **| raise Hcb::TokenExpiredError, "refresh token invalid or revoked" }

    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: []), "org_1")
    task_id = service.start_task!(kind: :cold, requested_by: "a")

    Hcb::Client.stub(:for_user, ->(_u) { fake_client }) do
      assert_nothing_raised { WarmOrganizationTransactionsJob.perform_now(user.id, "org_1", task_id: task_id) }
    end

    assert_equal "failed", service.progress.read[:phase]
    assert_match(/revoked/, service.progress.read[:error])
    assert_nil service.task_claim
  end
end
