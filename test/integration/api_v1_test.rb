require "test_helper"

class ApiV1Test < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(hcb_user_id: "usr_1", name: "Matt", email: "matt@example.com",
                         access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    @token = ApiToken.mint!(user: @user, name: "test token")

    # Newest-first, the order HCB returns them in.
    @outgoing = { "id" => "txn_out", "date" => "2026-01-02", "memo" => "Grant to Bar", "amount_cents" => -10_000 }
    @incoming = { "id" => "txn_in", "date" => "2026-01-01", "memo" => "Donation from Foo", "amount_cents" => 10_000 }
    @client = FakeHcbClient.new(
      transactions: [ @outgoing, @incoming ],
      organizations: [ { "id" => "org_1", "slug" => "clearinghouse", "name" => "Test Org" } ]
    )

    # These two balance each other, so the newest zero crossing lands on the
    # last of them and the working set would be empty. Pinning the cutoff to
    # the beginning of history puts both back in view, which is what these
    # tests are about.
    OrganizationSetting.create!(hcb_organization_id: "org_1", zero_balance_transaction_id: OrganizationLedger::BEGINNING_ID, updated_by: @user)
  end

  def auth_headers(token = @token.plaintext) = { "Authorization" => "Bearer #{token}" }

  def with_hcb(role = "member", &block)
    Hcb::Client.stub(:new, @client) { stub_membership(role, &block) }
  end

  def body = JSON.parse(response.body)

  test "a request without a usable token is refused and told how to authenticate" do
    get "/api/v1/organizations"
    assert_response :unauthorized
    assert_match(/Bearer/, response.headers["WWW-Authenticate"])
    assert_match(/Authorization: Bearer/, body["error"])

    get "/api/v1/organizations", headers: auth_headers("sy_wrong")
    assert_response :unauthorized

    @token.revoke!
    get "/api/v1/organizations", headers: auth_headers
    assert_response :unauthorized
  end

  test "me identifies the token and its owner" do
    get "/api/v1/me", headers: auth_headers
    assert_response :success
    assert_equal "usr_1", body["user"]["hcb_user_id"]
    assert_equal "test token", body["token"]["name"]
  end

  test "using a token records that it was used" do
    assert_nil @token.last_used_at
    get "/api/v1/me", headers: auth_headers
    assert @token.reload.last_used_at.present?
  end

  test "organizations lists what the token owner can reach on HCB" do
    with_hcb do
      get "/api/v1/organizations", headers: auth_headers
    end
    assert_response :success
    assert_equal [ "org_1" ], body["organizations"].map { |o| o["id"] }
  end

  test "a non-member gets the same not-found answer as a nonexistent organization" do
    with_hcb(nil) do
      get "/api/v1/organizations/org_1", headers: auth_headers
    end
    assert_response :not_found
    assert_equal "Organization not found.", body["error"]
  end

  test "the organization summary reports what is still unmatched" do
    with_hcb("reader") do
      get "/api/v1/organizations/org_1", headers: auth_headers
    end

    assert_response :success
    assert_equal "reader", body["organization"]["role"]
    assert_equal 1, body["unmatched"]["incoming_count"]
    assert_equal 1, body["unmatched"]["outgoing_count"]
    assert_in_delta 100.0, body["unmatched"]["incoming_total"], 0.001
    assert_in_delta(-100.0, body["unmatched"]["outgoing_total"], 0.001)
    assert_in_delta 0.0, body["unmatched"]["net"], 0.001
    assert_equal 0, body["matches"]["balanced"]
  end

  test "transactions can be filtered by direction, memo and amount" do
    with_hcb("reader") do
      get "/api/v1/organizations/org_1/transactions", headers: auth_headers
      assert_equal 2, body["total"]

      get "/api/v1/organizations/org_1/transactions", params: { direction: "in" }, headers: auth_headers
      assert_equal [ "txn_in" ], body["transactions"].map { |t| t["id"] }

      get "/api/v1/organizations/org_1/transactions", params: { query: "grant" }, headers: auth_headers
      assert_equal [ "txn_out" ], body["transactions"].map { |t| t["id"] }

      # Amounts are matched on magnitude, so the sign of the row doesn't matter.
      get "/api/v1/organizations/org_1/transactions", params: { min_amount: 50, max_amount: 150 }, headers: auth_headers
      assert_equal 2, body["total"]

      get "/api/v1/organizations/org_1/transactions", params: { after: "2026-01-02" }, headers: auth_headers
      assert_equal [ "txn_out" ], body["transactions"].map { |t| t["id"] }

      get "/api/v1/organizations/org_1/transactions", params: { limit: 1 }, headers: auth_headers
      assert_equal 2, body["total"]
      assert_equal 1, body["transactions"].size
    end
  end

  test "a transaction outside this organization's history is not found" do
    with_hcb("reader") do
      get "/api/v1/organizations/org_1/transactions/txn_elsewhere", headers: auth_headers
    end
    assert_response :not_found
  end

  test "a reader can read matches but not create one" do
    with_hcb("reader") do
      get "/api/v1/organizations/org_1/matches", headers: auth_headers
      assert_response :success
      assert_equal 0, body["total"]

      post "/api/v1/organizations/org_1/matches",
           params: { incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }, headers: auth_headers, as: :json
      assert_response :forbidden
      assert_match(/member/, body["error"])
    end
  end

  test "a member can create a match, see it, and undo it" do
    with_hcb("member") do
      post "/api/v1/organizations/org_1/matches",
           params: { incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ], note: "paid out in full" },
           headers: auth_headers, as: :json
      assert_response :created
      match = body
      assert_equal true, match["balanced"]
      assert_in_delta 0.0, match["discrepancy"], 0.001
      assert_equal "paid out in full", match["note"]
      assert_equal "Matt", match["created_by"]
      # The legs are spelled out, not just listed by id.
      assert_equal [ "Donation from Foo" ], match["incoming"].map { |t| t["memo"] }

      get "/api/v1/organizations/org_1/transactions", params: { status: "unmatched" }, headers: auth_headers
      assert_equal 0, body["total"]

      get "/api/v1/organizations/org_1/matches", params: { status: "balanced" }, headers: auth_headers
      assert_equal 1, body["total"]

      delete "/api/v1/organizations/org_1/matches/#{match["id"]}", headers: auth_headers
      assert_response :success
      assert Match.find(match["id"]).undone?

      get "/api/v1/organizations/org_1/transactions", params: { status: "unmatched" }, headers: auth_headers
      assert_equal 2, body["total"]
    end
  end

  test "an unbalanced match is saved as a discrepancy and reported as one" do
    with_hcb("member") do
      post "/api/v1/organizations/org_1/matches",
           params: { incoming_ids: [ "txn_in" ], outgoing_ids: [] }, headers: auth_headers, as: :json
      assert_response :created
      assert_equal false, body["balanced"]

      get "/api/v1/organizations/org_1/matches", params: { status: "unbalanced" }, headers: auth_headers
      assert_equal 1, body["total"]
    end
  end

  test "matching an already-matched transaction is a conflict, not a duplicate" do
    with_hcb("member") do
      post "/api/v1/organizations/org_1/matches", params: { incoming_ids: [ "txn_in" ] }, headers: auth_headers, as: :json
      assert_response :created

      post "/api/v1/organizations/org_1/matches", params: { incoming_ids: [ "txn_in" ] }, headers: auth_headers, as: :json
      assert_response :conflict
    end
  end

  test "ids sent as something other than a list are rejected rather than read as empty" do
    with_hcb("member") do
      post "/api/v1/organizations/org_1/matches", params: { incoming_ids: "txn_in" }, headers: auth_headers, as: :json
    end
    assert_response :bad_request
    assert_match(/list of transaction ids/, body["error"])
  end
end
