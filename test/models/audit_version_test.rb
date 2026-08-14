require "test_helper"

# What the change log actually captures, flow by flow. The point of these is
# less the plumbing than the questions the log has to be able to answer: what
# did this match used to pair, who changed it, and what moved on its own.
class AuditVersionTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_audit", name: "Ada", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    @match = Match.create!(hcb_organization_id: "org_1", note: "first", discrepancy_cents: 0, created_by: @user)
  end

  test "creating a match records a version stamped with its organization" do
    version = @match.versions.last

    assert_equal "create", version.event
    assert_equal "org_1", version.hcb_organization_id
    assert_equal "Match", version.item_type
  end

  test "an adjustment takes its organization from the match it adjusts" do
    adjustment = @match.adjustments.create!(amount_cents: 500, memo: "legacy leg", created_by: @user)

    assert_equal "org_1", adjustment.versions.last.hcb_organization_id
  end

  test "editing a match keeps what the note used to say" do
    @match.update!(note: "second")

    assert_equal [ "first", "second" ], @match.versions.last.object_changes["note"]
  end

  # The gap this was added for: Matches::Update replaces the legs wholesale, so
  # without the log there is nothing anywhere that says what the match paired
  # before the edit.
  test "legs discarded by an edit remain recoverable from the log" do
    @match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_old", direction: :incoming)
    @match.match_transactions.destroy_all

    discarded = AuditVersion.where(item_type: "MatchTransaction", event: "destroy")

    assert_equal [ "txn_old" ], discarded.map { |v| v.object["hcb_transaction_id"] }
  end

  test "cutoff changes are recorded against the organization" do
    setting = OrganizationSetting.create!(hcb_organization_id: "org_1", zero_balance_transaction_id: "txn_1", updated_by: @user)
    setting.update!(zero_balance_transaction_id: "txn_2")

    assert_equal [ "txn_1", "txn_2" ], setting.versions.last.object_changes["zero_balance_transaction_id"]
    assert_equal 2, AuditVersion.for_organization("org_1").where(item_type: "OrganizationSetting").count
  end

  test "whodunnit resolves to the person responsible" do
    PaperTrail.request(whodunnit: @user.id.to_s) { @match.update!(note: "by ada") }
    version = @match.versions.last

    assert_not version.system?
    assert_equal @user, version.user
    assert_equal "Ada", version.actor_name
  end

  test "a user since deleted leaves a readable version behind" do
    PaperTrail.request(whodunnit: "999999") { @match.update!(note: "by a ghost") }
    version = @match.versions.last

    assert_nil version.user
    assert_equal "unknown", version.actor_name
  end

  test "a system change names the process rather than a user" do
    PaperTrail.request(whodunnit: Matches::Resync::WHODUNNIT) { @match.update!(discrepancy_cents: 25) }
    version = @match.versions.last

    assert version.system?
    assert_nil version.user
    assert_equal "resync", version.actor_name
  end
end
