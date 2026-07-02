require "test_helper"

class Matches::CreateTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    @incoming = Hcb::TransactionPresenter.new({ "id" => "txn_in", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 10_000 })
    @outgoing = Hcb::TransactionPresenter.new({ "id" => "txn_out", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -10_000 })
    @by_id = { @incoming.id => @incoming, @outgoing.id => @outgoing }
  end

  def call(incoming_ids: [], outgoing_ids: [], note: "")
    Matches::Create.new(
      organization_id: "org_1", user: @user,
      incoming_ids: incoming_ids, outgoing_ids: outgoing_ids, note: note,
      transactions_by_id: @by_id
    ).call
  end

  test "requires at least one incoming or outgoing id" do
    result = call
    assert_not result.success?
    assert_equal :unprocessable_entity, result.status
  end

  test "creates a balanced match and computes a zero discrepancy" do
    result = call(incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ])
    assert result.success?
    assert_equal 0, result.match.discrepancy_cents
    assert_equal [ "txn_in" ], result.match.incoming_transaction_ids
    assert_equal [ "txn_out" ], result.match.outgoing_transaction_ids
  end

  test "creates an intentionally unbalanced match when only one side is selected" do
    result = call(incoming_ids: [ "txn_in" ], outgoing_ids: [])
    assert result.success?
    assert_equal 10_000, result.match.discrepancy_cents
  end

  test "rejects an incoming_id that is actually an outgoing transaction" do
    result = call(incoming_ids: [ "txn_out" ], outgoing_ids: [])
    assert_not result.success?
    assert_match(/not a valid incoming transaction/, result.error)
  end

  test "returns 409 conflict when the transaction was already claimed" do
    Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
      .match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)

    result = call(incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ])
    assert_not result.success?
    assert_equal :conflict, result.status
  end
end
