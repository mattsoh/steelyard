require "test_helper"

# What the change log reads like once it's aimed at a person rather than at a
# console. The interesting part isn't that the versions exist -- audit_version_test
# covers that -- it's that one thing somebody did comes back as one thing.
class Matches::HistoryTest < ActiveSupport::TestCase
  # Resync only ever asks the ledger for a leg's current amount.
  class StubLedger
    def initialize(amounts) = @amounts = amounts
    def transaction_by_id(id, remote: true) = @amounts.key?(id) ? Struct.new(:amount_cents).new(@amounts[id]) : nil
  end

  def setup
    @user = User.create!(hcb_user_id: "usr_hist", name: "Ada", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    @other = User.create!(hcb_user_id: "usr_hist_2", name: "Grace", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)

    @incoming = presenter("txn_in", 10_000)
    @outgoing = presenter("txn_out", -10_000)
    @other_outgoing = presenter("txn_out_2", -7_500)
    @by_id = [ @incoming, @outgoing, @other_outgoing ].index_by(&:id)
  end

  def presenter(id, amount_cents)
    Hcb::TransactionPresenter.new({ "id" => id, "date" => "2026-01-01", "memo" => id, "amount_cents" => amount_cents })
  end

  # Every change the app makes is written while serving a request, and that's
  # what ties the half-dozen versions one edit leaves behind back together.
  def as_request(request_id, user: @user)
    PaperTrail.request(whodunnit: user.id.to_s, controller_info: { request_id: request_id }) { yield }
  end

  def create_match(incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ], request_id: "req-create", user: @user)
    as_request(request_id, user: user) do
      Matches::Create.new(
        organization_id: "org_1", user: user,
        incoming_ids: incoming_ids, outgoing_ids: outgoing_ids, note: "", transactions_by_id: @by_id
      ).call.match
    end
  end

  def update_match(match, incoming_ids:, outgoing_ids:, note: "", request_id: "req-edit", user: @user)
    as_request(request_id, user: user) do
      Matches::Update.new(
        match: match, user: user,
        incoming_ids: incoming_ids, outgoing_ids: outgoing_ids, note: note, transactions_by_id: @by_id
      ).call
    end
  end

  test "a new match has one entry and nothing to report as an edit" do
    match = create_match

    history = Matches::History.for_match(match)
    entry = history.entries.sole

    assert_equal :created, entry.action
    assert_equal "Ada", entry.actor_name
    assert_not entry.system
    assert_nil history.last_edit
  end

  # The whole reason for grouping: Matches::Update destroys and recreates every
  # leg, so an edit that swapped one transaction writes two leg destroys, two
  # leg creates and a match update. Read raw that's five things nobody did.
  test "one edit is one entry, naming only what actually changed" do
    match = create_match
    update_match(match, incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out_2" ], user: @other)

    entries = Matches::History.for_match(match).entries
    assert_equal [ :created, :edited ], entries.map(&:action)

    edit = entries.last
    assert_equal "Grace", edit.actor_name
    legs = edit.changes.select { |c| c[:kind] == "leg" }
    assert_equal [
      { kind: "leg", action: "removed", direction: "outgoing", transaction_id: "txn_out" },
      { kind: "leg", action: "added", direction: "outgoing", transaction_id: "txn_out_2" }
    ], legs
  end

  test "an edit reports the discrepancy it moved and the note it set" do
    match = create_match
    update_match(match, incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out_2" ], note: "waiting on a receipt")

    edit = Matches::History.for_match(match).entries.last
    fields = edit.changes.reject { |c| c[:kind] == "leg" }

    assert_includes fields, { kind: "amount", label: "Discrepancy", from: 0.0, to: 25.0 }
    assert_includes fields, { kind: "text", label: "Note", from: "", to: "waiting on a receipt" }
  end

  test "an edit that leaves the legs alone doesn't claim to have changed them" do
    match = create_match
    update_match(match, incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ], note: "just a note")

    edit = Matches::History.for_match(match).entries.last
    assert_empty edit.changes.select { |c| c[:kind] == "leg" }
    assert_equal [ "Note" ], edit.changes.map { |c| c[:label] }
  end

  test "an undo is its own kind of entry, not another edit" do
    match = create_match
    as_request("req-undo") { Matches::Undo.new(match: match, user: @user).call }

    history = Matches::History.for_match(match)
    assert_equal [ :created, :undone ], history.entries.map(&:action)
    assert_equal :undone, history.last_edit.action
  end

  # Nobody touched the match: HCB restated a leg and the app re-derived what
  # it's now off by. Attributing that to a person would be a lie about who did
  # what, which is the one thing this log exists to get right.
  test "a re-derived discrepancy is reported as the process, not as an edit" do
    match = create_match
    ledger = StubLedger.new("txn_in" => 10_000, "txn_out" => -9_500)

    Matches::Resync.new(ledger: ledger, matches: [ match ]).call

    entry = Matches::History.for_match(match).entries.last
    assert_equal :resynced, entry.action
    assert entry.system
    assert_equal "resync", entry.actor_name
    assert_includes entry.changes, { kind: "amount", label: "Discrepancy", from: 0.0, to: 5.0 }
  end

  # A leg is gone from the database the moment an edit replaces it, so the only
  # thing that can say which match it belonged to is the version itself.
  test "matches don't inherit each other's history" do
    first = create_match(incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ], request_id: "req-a")
    second = create_match(incoming_ids: [], outgoing_ids: [ "txn_out_2" ], request_id: "req-b")
    update_match(second, incoming_ids: [], outgoing_ids: [ "txn_out_2" ], note: "second only", request_id: "req-c")

    histories = Matches::History.for_matches([ first, second ])

    assert_equal [ :created ], histories[first.id].entries.map(&:action)
    assert_equal [ :created, :edited ], histories[second.id].entries.map(&:action)
    assert_nil histories[first.id].last_edit
    assert_equal "Ada", histories[second.id].last_edit.actor_name
  end

  test "for_matches reads every match's history in one query" do
    matches = 3.times.map { |i| create_match(incoming_ids: [ "txn_in" ], outgoing_ids: [], request_id: "req-#{i}").tap { |m| m.match_transactions.destroy_all } }

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      Matches::History.for_matches(matches).each_value(&:entries)
    end

    # One for the versions, one for the people who wrote them.
    assert_equal 2, queries
  end
end
