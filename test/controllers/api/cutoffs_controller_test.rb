require "test_helper"

class Api::CutoffsControllerTest < ActionController::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    session[:user_id] = @user.id

    raw = [
      { "id" => "txn_3", "date" => "2026-01-03", "memo" => "Donation 2", "amount_cents" => 5_000 },
      { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant 1", "amount_cents" => -10_000 },
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation 1", "amount_cents" => 10_000 }
    ]
    @fake_client = FakeHcbClient.new(transactions: raw)
  end

  test "unauthenticated requests are redirected to login" do
    session[:user_id] = nil
    patch :update, params: { organization_id: "org_1", transaction_id: "txn_2" }
    assert_redirected_to login_path
  end

  test "a reader cannot change the cutoff" do
    Hcb::Client.stub :new, @fake_client do
      Hcb::OrganizationMembers.stub :role_for, "reader" do
        patch :update, params: { organization_id: "org_1", transaction_id: "txn_2" }
      end
    end
    assert_response :forbidden
  end

  test "a member cannot change the cutoff -- it can cascade-undo other people's matches" do
    Hcb::Client.stub :new, @fake_client do
      Hcb::OrganizationMembers.stub :role_for, "member" do
        patch :update, params: { organization_id: "org_1", transaction_id: OrganizationLedger::BEGINNING_ID }
      end
    end
    assert_response :forbidden
  end

  test "a manager can move the cutoff to a conflict-free option" do
    Hcb::Client.stub :new, @fake_client do
      Hcb::OrganizationMembers.stub :role_for, "manager" do
        patch :update, params: { organization_id: "org_1", transaction_id: OrganizationLedger::BEGINNING_ID }
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal OrganizationLedger::BEGINNING_ID, OrganizationSetting.find_by(hcb_organization_id: "org_1").zero_balance_transaction_id
  end

  test "rejects an unknown transaction id" do
    Hcb::Client.stub :new, @fake_client do
      Hcb::OrganizationMembers.stub :role_for, "manager" do
        patch :update, params: { organization_id: "org_1", transaction_id: "not_real" }
      end
    end
    assert_response :unprocessable_entity
  end

  test "a cutoff that splits an active match is reported with full leg details, not applied" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_1", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_3", direction: :outgoing)

    Hcb::Client.stub :new, @fake_client do
      Hcb::OrganizationMembers.stub :role_for, "manager" do
        patch :update, params: { organization_id: "org_1", transaction_id: "txn_2" }
      end
    end

    assert_response :conflict
    body = JSON.parse(response.body)
    conflict = body["conflicts"].sole
    assert_equal match.id, conflict["id"]
    assert_equal [ "txn_1" ], conflict["incoming"].map { |t| t["id"] }
    assert_equal [ "txn_3" ], conflict["outgoing"].map { |t| t["id"] }
    assert_nil OrganizationSetting.find_by(hcb_organization_id: "org_1")
    assert_not match.reload.undone?
  end

  test "confirming removes the conflicting match and applies the cutoff" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_1", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_3", direction: :outgoing)

    Hcb::Client.stub :new, @fake_client do
      Hcb::OrganizationMembers.stub :role_for, "manager" do
        patch :update, params: { organization_id: "org_1", transaction_id: "txn_2", confirm: true }
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ match.id ], body["removed_match_ids"]
    assert match.reload.undone?
    assert_equal "txn_2", OrganizationSetting.find_by(hcb_organization_id: "org_1").zero_balance_transaction_id
  end
end
