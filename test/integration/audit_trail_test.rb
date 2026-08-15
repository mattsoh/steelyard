require "test_helper"

# Attribution end to end. Everything below turns on the change reaching the
# audit log with the right person's name on it, which is the part the model
# tests can't see -- whodunnit is installed by a controller callback, and the
# two authenticated surfaces resolve their user at different moments.
class AuditTrailTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(hcb_user_id: "usr_1", name: "Matt", email: "matt@example.com",
                         access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)

    # Newest-first, the order HCB returns them in. The balance returns to zero
    # after txn_2 and again after txn_4, so both are offerable as cutoffs --
    # which the last test needs, since a cutoff that splits nothing undoes
    # nothing.
    transactions = [
      { "id" => "txn_5", "date" => "2026-01-05", "memo" => "Extra", "amount_cents" => 2_000 },
      { "id" => "txn_4", "date" => "2026-01-04", "memo" => "Grant 2", "amount_cents" => -5_000 },
      { "id" => "txn_3", "date" => "2026-01-03", "memo" => "Donation 2", "amount_cents" => 5_000 },
      { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant 1", "amount_cents" => -10_000 },
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation 1", "amount_cents" => 10_000 }
    ]
    @client = FakeHcbClient.new(
      transactions: transactions,
      organizations: [ { "id" => "org_1", "slug" => "clearinghouse", "name" => "Test Org" } ]
    )
    OrganizationSetting.create!(hcb_organization_id: "org_1", zero_balance_transaction_id: OrganizationLedger::BEGINNING_ID, updated_by: @user)
  end

  def with_hcb(role = "member", &block)
    Hcb::Client.stub(:new, @client) { stub_membership(role, &block) }
  end

  test "a match made in the web app is attributed to the signed-in user" do
    with_hcb do
      sign_in_via_hcb!(@user)
      post "/organizations/org_1/api/matches", params: { incoming_ids: [ "txn_1" ], outgoing_ids: [ "txn_2" ] }
      assert_response :created
    end

    version = Match.last.versions.last
    assert_equal @user, version.user
    assert_equal "Matt", version.actor_name
  end

  # The ordering trap ApplicationController's lambda exists for: on the token
  # surfaces `current_user` isn't known until TokenAuthenticated authenticates,
  # which happens *after* the inherited whodunnit callback has already run.
  # Read eagerly, this change would be credited to nobody.
  test "a match made with an API token is attributed to the token's owner" do
    token = ApiToken.mint!(user: @user, name: "test token")

    with_hcb do
      post "/api/v1/organizations/org_1/matches",
        params: { incoming_ids: [ "txn_1" ], outgoing_ids: [ "txn_2" ] },
        headers: { "Authorization" => "Bearer #{token.plaintext}" }
      assert_response :created
    end

    assert_equal @user, Match.last.versions.last.user
  end

  # What the detail popup and the match rows are actually reading: the log,
  # regrouped into one entry per thing somebody did. Worth doing end to end
  # rather than against hand-written versions, because the grouping keys on the
  # request id, which only a real request through the whole stack carries.
  test "a match reports who last edited it, and what that edit did" do
    editor = User.create!(hcb_user_id: "usr_2", name: "Grace", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    match = nil

    with_hcb do
      sign_in_via_hcb!(@user)
      post "/organizations/org_1/api/matches", params: { incoming_ids: [ "txn_1" ], outgoing_ids: [ "txn_2" ] }
      assert_response :created
      match = Match.last

      sign_in_via_hcb!(editor)
      patch "/organizations/org_1/api/matches/#{match.id}",
        params: { incoming_ids: [ "txn_1" ], outgoing_ids: [ "txn_4" ] }
      assert_response :success

      get "/organizations/org_1/api/matches/#{match.id}"
      assert_response :success
    end

    detail = JSON.parse(response.body)
    assert_equal "Matt", detail["created_by_name"]
    assert_equal true, detail["edited"]
    assert_equal "Grace", detail["last_edited_by_name"]

    # One edit, one entry -- not the five versions replacing both legs and
    # saving the match actually wrote.
    assert_equal [ "created", "edited" ], detail["history"].map { |e| e["action"] }
    edit = detail["history"].last
    assert_includes edit["changes"], { "kind" => "leg", "action" => "removed", "direction" => "outgoing", "transaction_id" => "txn_2" }
    assert_includes edit["changes"], { "kind" => "leg", "action" => "added", "direction" => "outgoing", "transaction_id" => "txn_4" }
    # The leg it dropped is named in full, though it is no longer part of the
    # match and nothing else on the page would have loaded it.
    assert_equal "Grant 1", detail.dig("transactions", "txn_2", "memo")
  end

  # Moving the cutoff cascade-undoes other people's matches. Those undos are
  # only distinguishable from six unrelated manual undos because they share the
  # request that caused them.
  test "matches undone by a cutoff move share a request with the cutoff change" do
    match = nil

    with_hcb("manager") do
      sign_in_via_hcb!(@user)
      # Straddles the cutoff moved to below: txn_1 falls behind it, txn_4 stays
      # in view, so applying it has to undo this match first.
      post "/organizations/org_1/api/matches", params: { incoming_ids: [ "txn_1" ], outgoing_ids: [ "txn_4" ] }
      assert_response :created
      match = Match.last

      patch "/organizations/org_1/api/cutoff", params: { transaction_id: "txn_2", confirm: true }
      assert_response :success
    end

    assert match.reload.undone?

    request_id = OrganizationSetting.find_by(hcb_organization_id: "org_1").versions.last.request_id
    caused = AuditVersion.for_request(request_id)

    assert_includes caused.map(&:item_type), "OrganizationSetting"
    assert_includes caused.where(item_type: "Match").map(&:item_id), match.id
    # The match's own creation was a separate request, so it must not be swept
    # in -- a request id that grouped everything would say nothing.
    assert_not_equal request_id, match.versions.first.request_id
  end
end
