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

  test "finishes a full reload the browser started and abandoned" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")

    # A tab claims the reload, streams two pages, then goes away.
    service.claim_full_reload!("stream-1")
    first = service.fetch_page(stream_id: "stream-1", limit: 2, reload: true)
    service.fetch_page(stream_id: "stream-1", after: first[:next_after], limit: 2, reload: true)
    assert_nil service.sync_state[:fetched_at]

    Hcb::Client.stub(:for_user, ->(_u) { fake_client }) do
      travel(Hcb::OrganizationTransactions::FULL_RELOAD_HEARTBEAT_TIMEOUT + 1.second) do
        WarmOrganizationTransactionsJob.perform_now(user.id, "org_1", full: true, stream_id: "stream-1")
      end
    end

    assert_equal transactions.map { |t| t["id"] }, service.all.map { |t| t["id"] }
    assert_nil service.full_reload_claim
  end

  test "checks back rather than draining alongside a stream that is still going" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")

    service.claim_full_reload!("stream-1")
    service.fetch_page(stream_id: "stream-1", limit: 2, reload: true)
    calls_before = fake_client.transactions_calls

    Hcb::Client.stub(:for_user, ->(_u) { fake_client }) do
      assert_enqueued_with(job: WarmOrganizationTransactionsJob) do
        WarmOrganizationTransactionsJob.perform_now(user.id, "org_1", full: true, stream_id: "stream-1")
      end
    end

    # The live stream is still the one drawing on the shared rate limit.
    assert_equal calls_before, fake_client.transactions_calls
    assert_nil service.sync_state[:fetched_at]
  end

  test "gives up rescheduling once a stream has outlasted every check" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    # More than one page left to walk, so the stream is genuinely still live --
    # otherwise this would stop rescheduling because the reload had *finished*,
    # which is a different reason and would prove nothing about the cap.
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)
    service = Hcb::OrganizationTransactions.new(fake_client, "org_1")
    service.claim_full_reload!("stream-1")
    service.fetch_page(stream_id: "stream-1", limit: 2, reload: true)
    assert_equal :running, service.resume_full_reload!("stream-1")

    Hcb::Client.stub(:for_user, ->(_u) { fake_client }) do
      assert_no_enqueued_jobs do
        WarmOrganizationTransactionsJob.perform_now(
          user.id, "org_1",
          full: true, stream_id: "stream-1",
          check: WarmOrganizationTransactionsJob::MAX_FALLBACK_CHECKS
        )
      end
    end
  end

  test "a failed takeover drops the claim rather than blocking the next attempt for its whole TTL" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..5).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    fake_client = FakeHcbClient.new(transactions: transactions)
    fake_client.define_singleton_method(:transactions) { |*, **| raise "HCB is down" }

    service = Hcb::OrganizationTransactions.new(FakeHcbClient.new(transactions: transactions), "org_1")
    service.claim_full_reload!("stream-1")

    Hcb::Client.stub(:for_user, ->(_u) { fake_client }) do
      travel(Hcb::OrganizationTransactions::FULL_RELOAD_HEARTBEAT_TIMEOUT + 1.second) do
        assert_raises(RuntimeError) do
          WarmOrganizationTransactionsJob.perform_now(user.id, "org_1", full: true, stream_id: "stream-1")
        end
      end
    end

    assert_nil service.full_reload_claim
  end
end
