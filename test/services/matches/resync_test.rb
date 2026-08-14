require "test_helper"

class Matches::ResyncTest < ActiveSupport::TestCase
  # Resync only ever asks the ledger for a leg's current amount, so the whole
  # HCB drain isn't needed to exercise it -- just somewhere to put the amounts.
  class StubLedger
    def initialize(amounts) = @amounts = amounts
    def transaction_by_id(id, remote: true) = @amounts.key?(id) ? Struct.new(:amount_cents).new(@amounts[id]) : nil
  end

  def setup
    @user = User.create!(hcb_user_id: "usr_resync", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    @match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    @match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    @match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)
  end

  def resync(amounts) = Matches::Resync.new(ledger: StubLedger.new(amounts), matches: [ @match ]).call

  test "a leg restated by HCB moves the discrepancy" do
    changes = resync("txn_in" => 10_000, "txn_out" => -9_500)

    assert_equal [ 500 ], changes.map(&:to_cents)
    assert_equal 500, @match.reload.discrepancy_cents
  end

  test "a match that still adds up is left alone" do
    assert_empty resync("txn_in" => 10_000, "txn_out" => -10_000)
  end

  # Nobody edited this match -- HCB restated a transaction underneath it. The
  # log has to say that rather than blame whoever's page load happened to
  # notice, which is why Resync sets its own whodunnit.
  test "the resulting version is attributed to the process, not a user" do
    PaperTrail.request(whodunnit: @user.id.to_s) do
      resync("txn_in" => 10_000, "txn_out" => -9_500)
    end

    version = @match.versions.last
    assert version.system?
    assert_equal "resync", version.actor_name
  end

  test "an ordinary edit after a resync is still attributed to the user" do
    PaperTrail.request(whodunnit: @user.id.to_s) do
      resync("txn_in" => 10_000, "txn_out" => -9_500)
      @match.update!(note: "checked")
    end

    assert_equal @user, @match.versions.last.user
  end
end
