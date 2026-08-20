require "test_helper"

class Matches::ResyncTest < ActiveSupport::TestCase
  # Resync asks the ledger for a leg's current amount, and -- only when one
  # doesn't resolve -- whether there is a drain to have missed it from. So the
  # whole HCB drain isn't needed to exercise it: somewhere to put the amounts,
  # and a #transactions standing in for "the drain is there".
  class StubLedger
    def initialize(amounts, drained: true)
      @amounts = amounts
      @drained = drained
    end

    def transaction_by_id(id, remote: true) = @amounts.key?(id) ? Struct.new(:amount_cents).new(@amounts[id]) : nil

    # Only ever asked whether it's empty -- "is there a drain at all", not
    # what's in it. Independent of @amounts on purpose, so a test can have a
    # drain that simply doesn't contain the legs being looked up.
    def transactions = @drained ? [ :a_drained_transaction ] : []
  end

  def setup
    @user = User.create!(hcb_user_id: "usr_resync", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    @match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    @match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    @match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)
  end

  def resync(amounts, drained: true)
    Matches::Resync.new(ledger: StubLedger.new(amounts, drained: drained), matches: [ @match ]).call
  end

  test "a leg restated by HCB moves the discrepancy" do
    result = resync({ "txn_in" => 10_000, "txn_out" => -9_500 })

    assert_equal [ 500 ], result.changes.map(&:to_cents)
    assert_empty result.unresolved
    assert_equal 500, @match.reload.discrepancy_cents
  end

  test "a match that still adds up is left alone" do
    result = resync({ "txn_in" => 10_000, "txn_out" => -10_000 })

    assert_empty result.changes
    assert_empty result.unresolved
  end

  test "a leg HCB no longer has is dropped from the match and the rest re-derived" do
    result = resync({ "txn_in" => 10_000 })

    dropped = result.dropped.sole
    assert_equal @match.id, dropped.match.id
    assert_equal [ "txn_out" ], dropped.transaction_ids
    assert_equal 0, dropped.from_cents
    assert_equal 10_000, dropped.to_cents
    assert_not dropped.match_undone

    # The match now pairs only what's left, so it's off by that leg's amount --
    # a balanced match becoming unbalanced is a real change in what it claims.
    assert_equal 10_000, @match.reload.discrepancy_cents
    # The dropped row is kept, not deleted -- it's what lets the leg come back
    # if the transaction is remapped into the organization again.
    assert_equal [ "txn_in" ], @match.match_transactions.active.map(&:hcb_transaction_id)
    assert_equal [ "txn_out" ], @match.match_transactions.dropped.map(&:hcb_transaction_id)
  end

  test "dropping a leg is recorded as a removal in the match's history" do
    resync({ "txn_in" => 10_000 })

    entry = Matches::History.for_match(@match.reload).entries.last
    assert entry.system
    assert_equal "resync", entry.actor_name
    assert_includes entry.changes, { kind: "leg", action: "removed", direction: "outgoing", transaction_id: "txn_out" }
  end

  test "a match whose every leg has gone is undone rather than left pairing nothing" do
    result = resync({})

    dropped = result.dropped.sole
    assert_equal [ "txn_in", "txn_out" ], dropped.transaction_ids
    assert dropped.match_undone
    # A zero-leg match would otherwise sit in the matcher looking balanced while
    # accounting for nothing at all.
    assert @match.reload.undone?
    assert_empty @match.match_transactions.active
  end

  test "dropping a leg can make a match balance" do
    @match.update!(discrepancy_cents: -500)
    @match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_stray", direction: :outgoing)

    result = resync({ "txn_in" => 10_000, "txn_out" => -10_000 })

    assert_equal [ "txn_stray" ], result.dropped.sole.transaction_ids
    assert_equal 0, result.dropped.sole.to_cents
    assert_equal 0, @match.reload.discrepancy_cents
  end

  test "a leg comes back when the transaction is accounted for again" do
    # Remapped out of the organization, so the leg is dropped and the match is
    # off by what's left.
    resync({ "txn_in" => 10_000 })
    assert_equal 10_000, @match.reload.discrepancy_cents

    # Remapped back. Somebody undoing their own mistake on HCB shouldn't need
    # to rebuild the match here, which is why the drop marked the row instead
    # of deleting it.
    result = resync({ "txn_in" => 10_000, "txn_out" => -10_000 })

    restored = result.restored.sole
    assert_equal [ "txn_out" ], restored.transaction_ids
    assert_equal 10_000, restored.from_cents
    assert_equal 0, restored.to_cents
    assert_equal 0, @match.reload.discrepancy_cents
    assert_equal [ "txn_in", "txn_out" ], @match.match_transactions.active.map(&:hcb_transaction_id).sort
  end

  test "a restore is recorded in the match's history as the leg returning" do
    resync({ "txn_in" => 10_000 })
    resync({ "txn_in" => 10_000, "txn_out" => -10_000 })

    entry = Matches::History.for_match(@match.reload).entries.last
    assert_includes entry.changes, { kind: "leg", action: "restored", direction: "outgoing", transaction_id: "txn_out" }
  end

  test "a match undone only because it ran out of legs comes back when they do" do
    resync({})
    assert @match.reload.undone?

    result = resync({ "txn_in" => 10_000, "txn_out" => -10_000 })

    assert_equal 2, result.restored.sole.transaction_ids.size
    assert_not @match.reload.undone?
    assert_equal 0, @match.discrepancy_cents
  end

  test "a match a person undid stays undone even when its legs come back" do
    resync({})
    @match.reload.update!(undone_by: @user)

    resync({ "txn_in" => 10_000, "txn_out" => -10_000 })

    # Undoing it was a decision, not a consequence of HCB losing something.
    assert @match.reload.undone?
  end

  test "force_prune applies drops the safety valve would refuse" do
    matches = Array.new(6) do |n|
      m = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
      m.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_gone_#{n}", direction: :incoming)
      m
    end

    ledger = StubLedger.new({})
    assert_equal 6, Matches::Resync.new(ledger: ledger, matches: matches).call.unresolved.size

    forced = Matches::Resync.new(ledger: ledger, matches: matches, force_prune: true).call

    assert_equal 6, forced.dropped.size
    assert_empty forced.unresolved
    matches.each { |m| assert_empty m.match_transactions.active }
  end

  test "a mass disappearance is reported rather than applied, on the grounds the drain is wrong" do
    # Well past the floor and the whole batch, so this is a drain that came back
    # short rather than HCB losing everything at once. Pruning here would gut
    # every match in the organization off the back of a bad cache read.
    matches = Array.new(6) do |n|
      m = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
      m.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_gone_#{n}", direction: :incoming)
      m
    end

    result = Matches::Resync.new(ledger: StubLedger.new({}), matches: matches).call

    assert_empty result.dropped
    assert_equal 6, result.unresolved.size
    matches.each { |m| assert_equal 1, m.match_transactions.active.count }
  end

  test "a leg is only called missing when there is a drain to have missed it from" do
    # No drain -- a full reload's purge, or one that hasn't landed. Every leg
    # looks gone, and dropping them all on the strength of that would destroy
    # every match in the organization.
    result = resync({}, drained: false)

    assert_empty result.changes
    assert_empty result.dropped
    assert_empty result.unresolved
    assert_equal 0, @match.reload.discrepancy_cents
    assert_equal 2, @match.match_transactions.active.count
  end

  # Nobody edited this match -- HCB restated a transaction underneath it. The
  # log has to say that rather than blame whoever's page load happened to
  # notice, which is why Resync sets its own whodunnit.
  test "the resulting version is attributed to the process, not a user" do
    PaperTrail.request(whodunnit: @user.id.to_s) do
      resync({ "txn_in" => 10_000, "txn_out" => -9_500 })
    end

    version = @match.versions.last
    assert version.system?
    assert_equal "resync", version.actor_name
  end

  test "an ordinary edit after a resync is still attributed to the user" do
    PaperTrail.request(whodunnit: @user.id.to_s) do
      resync({ "txn_in" => 10_000, "txn_out" => -9_500 })
      @match.update!(note: "checked")
    end

    assert_equal @user, @match.versions.last.user
  end
end
