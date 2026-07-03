require "test_helper"

class Cutoffs::UpdateTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_cutoff", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)

    raw = [
      { "id" => "txn_5", "date" => "2026-01-05", "memo" => "Extra", "amount_cents" => 2_000 },
      { "id" => "txn_4", "date" => "2026-01-04", "memo" => "Grant 2", "amount_cents" => -5_000 },
      { "id" => "txn_3", "date" => "2026-01-03", "memo" => "Donation 2", "amount_cents" => 5_000 },
      { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant 1", "amount_cents" => -10_000 },
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation 1", "amount_cents" => 10_000 }
    ]
    @client = FakeHcbClient.new(transactions: raw)
    @ledger = OrganizationLedger.new(@client, "org_1")

    @match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    @match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_1", direction: :incoming)
    @match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_3", direction: :outgoing)
  end

  def call(transaction_id:, confirm:)
    Cutoffs::Update.new(
      organization_id: "org_1", user: @user, ledger: @ledger, transaction_id: transaction_id, confirm: confirm
    ).call
  end

  test "rejects a transaction id that isn't a valid cutoff option" do
    result = call(transaction_id: "not_real", confirm: false)

    assert_not result.success?
    assert_equal :unprocessable_entity, result.status
    assert_nil OrganizationSetting.find_by(hcb_organization_id: "org_1")
  end

  test "moving the cutoff without conflicts saves the setting immediately" do
    result = call(transaction_id: OrganizationLedger::BEGINNING_ID, confirm: false)

    assert result.success?
    setting = OrganizationSetting.find_by(hcb_organization_id: "org_1")
    assert_equal OrganizationLedger::BEGINNING_ID, setting.zero_balance_transaction_id
    assert_equal @user, setting.updated_by
    assert_not @match.reload.undone?
  end

  test "a candidate cutoff that splits an active match is reported, not applied" do
    result = call(transaction_id: "txn_2", confirm: false)

    assert_not result.success?
    assert_equal :conflict, result.status
    assert_equal [ @match.id ], result.conflicts.map(&:id)
    assert_nil OrganizationSetting.find_by(hcb_organization_id: "org_1")
    assert_not @match.reload.undone?
  end

  test "confirming removes the conflicting matches and applies the cutoff" do
    result = call(transaction_id: "txn_2", confirm: true)

    assert result.success?
    assert_equal [ @match.id ], result.removed_match_ids
    assert @match.reload.undone?

    setting = OrganizationSetting.find_by(hcb_organization_id: "org_1")
    assert_equal "txn_2", setting.zero_balance_transaction_id
  end

  test "a match undone by someone else between the read and the undo loop is skipped, not double-processed" do
    stale_copy = Match.find(@match.id)
    @match.update!(undone_at: Time.current, undone_by: @user)

    service = Cutoffs::Update.new(organization_id: "org_1", user: @user, ledger: @ledger, transaction_id: "txn_2", confirm: true)
    service.stub(:conflicting_matches, [ stale_copy ]) do
      result = service.call

      assert result.success?
      assert_empty result.removed_match_ids
      assert_equal "txn_2", OrganizationSetting.find_by(hcb_organization_id: "org_1").zero_balance_transaction_id
    end
  end

  test "a concurrent duplicate OrganizationSetting write is reported as a conflict, not a raised error" do
    OrganizationSetting.stub(:find_or_initialize_by, ->(*) { raise ActiveRecord::RecordNotUnique, "boom" }) do
      result = call(transaction_id: OrganizationLedger::BEGINNING_ID, confirm: false)

      assert_not result.success?
      assert_equal :conflict, result.status
    end
  end
end
