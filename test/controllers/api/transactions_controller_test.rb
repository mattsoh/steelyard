require "test_helper"

class Api::TransactionsControllerTest < ActionController::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    session[:user_id] = @user.id
  end

  test "returns windowed transactions plus any older ones referenced by an active match" do
    windowed = { "id" => "txn_recent", "date" => "2026-06-01", "memo" => "Recent donation", "amount_cents" => 5_000 }
    aged_out = { "id" => "txn_old", "date" => "2020-01-01", "memo" => "Old grant", "amount_cents" => -5_000 }
    fake_client = FakeHcbClient.new(transactions: [ windowed ]) # aged_out is NOT in the cached window
    fake_client.define_singleton_method(:transaction) { |id| id == "txn_old" ? aged_out : nil }

    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_old", direction: :outgoing)

    Hcb::Client.stub :new, fake_client do
      Hcb::OrganizationMembers.stub :role_for, "reader" do
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
      Hcb::OrganizationMembers.stub :role_for, "reader" do
        get :index, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    options = JSON.parse(response.body)["zero_balance_options"]
    beginning = options.find { |o| o["transaction_id"] == OrganizationLedger::BEGINNING_ID }
    assert beginning
    assert_equal true, beginning["beginning"]
  end
end
