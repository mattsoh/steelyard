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
end
