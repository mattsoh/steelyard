require "test_helper"

class OrganizationLedgerTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_ledger", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)

    # Raw HCB feed arrives newest-first; OrganizationLedger reverses it to
    # oldest-first before computing a running balance.
    raw = [
      { "id" => "txn_5", "date" => "2026-01-05", "memo" => "Extra", "amount_cents" => 2_000 },
      { "id" => "txn_4", "date" => "2026-01-04", "memo" => "Grant 2", "amount_cents" => -5_000 },
      { "id" => "txn_3", "date" => "2026-01-03", "memo" => "Donation 2", "amount_cents" => 5_000 },
      { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant 1", "amount_cents" => -10_000 },
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation 1", "amount_cents" => 10_000 }
    ]
    @client = FakeHcbClient.new(transactions: raw)
    @ledger = OrganizationLedger.new(@client, "org_1")
  end

  test "transactions are oldest-first with a running balance" do
    assert_equal %w[txn_1 txn_2 txn_3 txn_4 txn_5], @ledger.transactions.map(&:id)
    assert_equal [ 10_000, 0, 5_000, 0, 2_000 ], @ledger.running_balance_cents
  end

  test "zero_options includes every zero-crossing plus the beginning of history" do
    ids = @ledger.zero_options.map(&:transaction_id)
    assert_equal [ "txn_4", "txn_2", OrganizationLedger::BEGINNING_ID ], ids

    beginning = @ledger.zero_options.last
    assert beginning.beginning?
    assert_equal "2026-01-01", beginning.date
  end

  test "defaults to the most recent zero crossing when nothing is chosen" do
    assert_equal "txn_4", @ledger.effective_cutoff.transaction_id
    assert_equal %w[txn_5], @ledger.after_cutoff.map(&:id)
  end

  test "classify reflects the effective cutoff" do
    hidden_ids = %w[txn_1 txn_2]
    visible_ids = %w[txn_5]
    overlapping_ids = %w[txn_3 txn_5]

    assert_equal :hidden, @ledger.classify(hidden_ids)
    assert_equal :visible, @ledger.classify(visible_ids)
    assert_equal :overlapping, @ledger.classify(overlapping_ids)
  end

  test "choosing the beginning of history reveals everything and clears conflicts" do
    OrganizationSetting.create!(hcb_organization_id: "org_1", zero_balance_transaction_id: OrganizationLedger::BEGINNING_ID, updated_by: @user)
    ledger = OrganizationLedger.new(@client, "org_1")

    assert_equal(-1, ledger.cutoff_index)
    assert_equal %w[txn_1 txn_2 txn_3 txn_4 txn_5], ledger.after_cutoff.map(&:id)
    assert_equal :visible, ledger.classify(%w[txn_1 txn_2])
    assert_equal :visible, ledger.classify(%w[txn_3 txn_5])
  end

  test "choosing an earlier cutoff changes which matches would overlap" do
    OrganizationSetting.create!(hcb_organization_id: "org_1", zero_balance_transaction_id: "txn_2", updated_by: @user)
    ledger = OrganizationLedger.new(@client, "org_1")

    assert_equal %w[txn_3 txn_4 txn_5], ledger.after_cutoff.map(&:id)
    assert_equal :hidden, ledger.classify(%w[txn_1 txn_2])
    assert_equal :visible, ledger.classify(%w[txn_3 txn_5])
  end
end
