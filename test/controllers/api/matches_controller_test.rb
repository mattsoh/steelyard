require "test_helper"

class Api::MatchesControllerTest < ActionController::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    incoming = { "id" => "txn_in", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 10_000 }
    outgoing = { "id" => "txn_out", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -10_000 }
    @fake_client = FakeHcbClient.new(transactions: [ incoming, outgoing ])
    session[:user_id] = @user.id
  end

  test "unauthenticated requests are redirected to login" do
    session[:user_id] = nil
    get :index, params: { organization_id: "org_1" }
    assert_redirected_to root_path
  end

  test "a non-member gets the same not-found response as a nonexistent org" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership(nil) do
        get :index, params: { organization_id: "org_1" }
      end
    end
    assert_response :not_found
  end

  test "a reader can list matches but cannot create one" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
        assert_response :success

        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :forbidden
      end
    end
  end

  test "a member can create and then undo a match" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :created
        match_id = JSON.parse(response.body)["id"]

        delete :destroy, params: { organization_id: "org_1", id: match_id }
        assert_response :success
        assert Match.find(match_id).undone?
      end
    end
  end

  test "create returns the fully serialized match, not just id/discrepancy" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :created

        match = JSON.parse(response.body)
        assert_equal [ "txn_in" ], match["incoming_ids"]
        assert_equal [ "txn_out" ], match["outgoing_ids"]
        assert_equal 0, match["discrepancy"]
        assert_equal false, match["conflict"]
        assert match.key?("created_by_name")
        assert match["created_at"].present?
      end
    end
  end

  test "index does not flag an ordinary match as a conflict" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("manager") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :created

        get :index, params: { organization_id: "org_1" }
        assert_response :success
        match = JSON.parse(response.body)["matches"].sole
        assert_equal false, match["conflict"]
      end
    end
  end

  test "index flags a match whose legs span the effective cutoff as a conflict" do
    raw = [
      { "id" => "txn_C", "date" => "2026-01-03", "memo" => "Extra", "amount_cents" => 5_000 },
      { "id" => "txn_B", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -10_000 },
      { "id" => "txn_A", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 10_000 }
    ]
    fake_client = FakeHcbClient.new(transactions: raw)

    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_A", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_C", direction: :outgoing)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    found = JSON.parse(response.body)["matches"].sole
    assert_equal match.id, found["id"]
    assert_equal true, found["conflict"]
  end

  test "show returns the match with its legs resolved and its history" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        match = Match.create!(hcb_organization_id: "org_1", note: "for the workshop", discrepancy_cents: 0, created_by: @user)
        match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
        match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

        get :show, params: { organization_id: "org_1", id: match.id }
        assert_response :success

        body = JSON.parse(response.body)
        assert_equal [ "txn_in" ], body["incoming_ids"]
        assert_equal "for the workshop", body["note"]
        assert_equal false, body["edited"]
        # The legs come back as whole transactions, so the popup can name them
        # without the page it opened over having loaded them.
        assert_equal "Donation", body.dig("transactions", "txn_in", "memo")
        assert_equal(-100.0, body.dig("transactions", "txn_out", "amount"))
        assert_equal [ "created" ], body["history"].map { |e| e["action"] }
        assert body.key?("created_by_name")
        assert body["created_at"].present?
      end
    end
  end

  # The one view where an undone match is still worth reading: a link to one
  # should explain what happened to it rather than 404.
  test "show still answers for a match that has been undone" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        match_id = JSON.parse(response.body)["id"]
        delete :destroy, params: { organization_id: "org_1", id: match_id }

        get :show, params: { organization_id: "org_1", id: match_id }
        assert_response :success

        body = JSON.parse(response.body)
        assert_equal true, body["undone"]
        assert body["undone_at"].present?
        assert_includes body["history"].map { |e| e["action"] }, "undone"
        # Undoing marks the legs undone too, so reporting only live ones would
        # leave the popup saying this match paired nothing at all.
        assert_equal [ "txn_in" ], body["incoming_ids"]
        assert_equal [ "txn_out" ], body["outgoing_ids"]
        assert_equal "Grant", body.dig("transactions", "txn_out", "memo")
      end
    end
  end

  test "show does not reach a match belonging to another organization" do
    other = Match.create!(hcb_organization_id: "org_2", discrepancy_cents: 0, created_by: @user)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("manager") do
        get :show, params: { organization_id: "org_1", id: other.id }
      end
    end
    assert_response :not_found
  end

  test "matching the same transaction twice returns a conflict" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("manager") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [] }
        assert_response :created

        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [] }
        assert_response :conflict
      end
    end
  end
end
