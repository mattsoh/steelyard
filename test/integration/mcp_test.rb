require "test_helper"

class McpTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(hcb_user_id: "usr_1", name: "Matt", email: "matt@example.com",
                         access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    @token = ApiToken.mint!(user: @user, name: "assistant")

    @outgoing = { "id" => "txn_out", "date" => "2026-01-02", "memo" => "Grant to Bar", "amount_cents" => -10_000 }
    @incoming = { "id" => "txn_in", "date" => "2026-01-01", "memo" => "Donation from Foo", "amount_cents" => 10_000 }
    @client = FakeHcbClient.new(
      transactions: [ @outgoing, @incoming ],
      organizations: [ { "id" => "org_1", "slug" => "clearinghouse", "name" => "Test Org" } ]
    )

    # See ApiV1Test: without this the two balancing transactions sit on the far
    # side of the cutoff and the working set is empty.
    OrganizationSetting.create!(hcb_organization_id: "org_1", zero_balance_transaction_id: OrganizationLedger::BEGINNING_ID, updated_by: @user)
  end

  def auth_headers
    { "Authorization" => "Bearer #{@token.plaintext}", "Content-Type" => "application/json" }
  end

  def rpc(message, headers: auth_headers)
    post "/mcp", params: message.to_json, headers: headers
    response.body.present? ? JSON.parse(response.body) : nil
  end

  def with_hcb(role = "member", &block)
    Hcb::Client.stub(:new, @client) { stub_membership(role, &block) }
  end

  def call_tool(name, arguments = {}, id: 1)
    rpc({ jsonrpc: "2.0", id: id, method: "tools/call", params: { name: name, arguments: arguments } })
  end

  # A tool's answer is JSON carried as text, so the assertions read it back out.
  def tool_payload(reply) = JSON.parse(reply["result"]["content"].first["text"])

  test "an unauthenticated call is refused in the client's own protocol" do
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
    assert_match(/Bearer/, response.headers["WWW-Authenticate"])
    assert_equal "2.0", JSON.parse(response.body)["jsonrpc"]
    assert JSON.parse(response.body)["error"]["message"].present?
  end

  test "initialize answers with the protocol version the client asked for" do
    reply = rpc({ jsonrpc: "2.0", id: 1, method: "initialize",
                  params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "test", version: "1" } } })

    assert_response :success
    assert_equal "2025-03-26", reply["result"]["protocolVersion"]
    assert_equal "steelyard", reply["result"]["serverInfo"]["name"]
    assert reply["result"]["capabilities"].key?("tools")
    assert_match(/reconcil/i, reply["result"]["instructions"])
  end

  test "initialize falls back to a version this server speaks" do
    reply = rpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "1999-01-01" } })
    assert_equal Mcp::Server::PROTOCOL_VERSION, reply["result"]["protocolVersion"]
  end

  test "a notification is accepted with nothing said back" do
    post "/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json, headers: auth_headers

    assert_response :accepted
    assert_empty response.body
  end

  test "tools/list describes every tool with a schema" do
    reply = rpc({ jsonrpc: "2.0", id: 2, method: "tools/list" })
    tools = reply["result"]["tools"]

    assert_equal Mcp::Tools::ALL.size, tools.size
    assert_includes tools.map { |t| t["name"] }, "create_match"
    tools.each do |tool|
      assert tool["description"].present?, "#{tool["name"]} has no description"
      assert_equal "object", tool["inputSchema"]["type"]
    end
  end

  test "an unknown method and an unknown tool are both reported as protocol errors" do
    assert_equal(-32601, rpc({ jsonrpc: "2.0", id: 3, method: "resources/list" })["error"]["code"])
    assert_equal(-32602, call_tool("no_such_tool")["error"]["code"])
  end

  test "the read tools answer with the same figures the API reports" do
    with_hcb("reader") do
      assert_equal [ "org_1" ], tool_payload(call_tool("list_organizations"))["organizations"].map { |o| o["id"] }

      summary = tool_payload(call_tool("get_reconciliation_summary", { "organization_id" => "org_1" }))
      assert_equal 1, summary["unmatched"]["incoming_count"]
      assert_equal 1, summary["unmatched"]["outgoing_count"]

      listed = tool_payload(call_tool("list_transactions", { "organization_id" => "org_1", "status" => "unmatched", "direction" => "out" }))
      assert_equal [ "txn_out" ], listed["transactions"].map { |t| t["id"] }

      one = tool_payload(call_tool("get_transaction", { "organization_id" => "org_1", "transaction_id" => "txn_in" }))
      assert_equal "Donation from Foo", one["memo"]
      assert_equal false, one["matched"]
    end
  end

  test "a member can match and unmatch through the tools" do
    with_hcb("member") do
      created = tool_payload(call_tool("create_match", {
        "organization_id" => "org_1", "incoming_ids" => [ "txn_in" ], "outgoing_ids" => [ "txn_out" ]
      }))
      assert_equal true, created["balanced"]

      matches = tool_payload(call_tool("list_matches", { "organization_id" => "org_1" }))
      assert_equal 1, matches["total"]

      undone = tool_payload(call_tool("undo_match", { "organization_id" => "org_1", "match_id" => created["id"] }))
      assert_equal true, undone["undone"]
      assert Match.find(created["id"]).undone?
    end
  end

  # The tool exists so an incomplete match can be finished rather than undone
  # and rebuilt, so what matters is that the fields nobody sent survive it.
  test "update_match changes only what the call mentioned" do
    with_hcb("member") do
      id = tool_payload(call_tool("create_match", {
        "organization_id" => "org_1", "incoming_ids" => [ "txn_in" ], "outgoing_ids" => []
      }))["id"]

      noted = tool_payload(call_tool("update_match", {
        "organization_id" => "org_1", "match_id" => id, "note" => "grant still pending"
      }))
      assert_equal "grant still pending", noted["note"]
      assert_equal [ "txn_in" ], noted["incoming_ids"]
      assert_equal false, noted["balanced"]

      filled = tool_payload(call_tool("update_match", {
        "organization_id" => "org_1", "match_id" => id, "outgoing_ids" => [ "txn_out" ]
      }))
      assert_equal true, filled["balanced"]
      assert_equal "grant still pending", filled["note"]
      # The edits are on the record, which is the reason to prefer this over
      # undoing and re-creating.
      assert_equal [ "created", "edited", "edited" ], filled["history"].map { |e| e["action"] }
      assert_equal "Matt", filled["last_edited_by"]
    end
  end

  test "a role that cannot match cannot edit one either" do
    id = with_hcb("member") do
      tool_payload(call_tool("create_match", {
        "organization_id" => "org_1", "incoming_ids" => [ "txn_in" ], "outgoing_ids" => [ "txn_out" ]
      }))["id"]
    end

    with_hcb("reader") do
      reply = call_tool("update_match", { "organization_id" => "org_1", "match_id" => id, "note" => "no" })

      assert_equal true, reply["result"]["isError"]
      assert_match(/members and managers/, tool_payload(reply)["error"])
    end
  end

  # The question a model asks before touching somebody else's match: who made
  # this, and has anyone argued with it since?
  test "get_match answers with the change history behind one match" do
    id = nil

    with_hcb("member") do
      id = tool_payload(call_tool("create_match", {
        "organization_id" => "org_1", "incoming_ids" => [ "txn_in" ], "outgoing_ids" => []
      }))["id"]
    end

    editor = User.create!(hcb_user_id: "usr_2", name: "Grace", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    by_id = [ @incoming, @outgoing ].to_h { |raw| [ raw["id"], Hcb::TransactionPresenter.new(raw) ] }
    PaperTrail.request(whodunnit: editor.id.to_s, controller_info: { request_id: "req-edit" }) do
      Matches::Update.new(match: Match.find(id), user: editor, incoming_ids: [ "txn_in" ],
                          outgoing_ids: [ "txn_out" ], note: "paid out in full", transactions_by_id: by_id).call
    end

    with_hcb("reader") do
      found = tool_payload(call_tool("get_match", { "organization_id" => "org_1", "match_id" => id }))

      assert_equal id, found["id"]
      assert_equal "Matt", found["created_by"]
      assert_equal "Grace", found["last_edited_by"]
      assert_equal [ "created", "edited" ], found["history"].map { |e| e["action"] }
      # Named rather than left as ids, so a model can weigh the change without
      # a lookup per leg.
      assert_equal [ "Grant to Bar" ], found["outgoing"].map { |t| t["memo"] }
    end
  end

  test "get_match reports a match this organization doesn't have" do
    with_hcb("reader") do
      reply = call_tool("get_match", { "organization_id" => "org_1", "match_id" => 999_999 })

      assert_equal true, reply["result"]["isError"]
      assert_match(/No match/, tool_payload(reply)["error"])
    end
  end

  # A refusal the model is meant to read and act on comes back as a tool result
  # flagged isError, not as a JSON-RPC error the client would swallow.
  test "a role that cannot match is reported to the model, not to the transport" do
    with_hcb("reader") do
      reply = call_tool("create_match", { "organization_id" => "org_1", "incoming_ids" => [ "txn_in" ] })

      assert_response :success
      assert_nil reply["error"]
      assert_equal true, reply["result"]["isError"]
      assert_match(/members and managers/, tool_payload(reply)["error"])
    end
  end

  test "an organization the token cannot see is reported the same way" do
    with_hcb(nil) do
      reply = call_tool("get_reconciliation_summary", { "organization_id" => "org_1" })
      assert_equal true, reply["result"]["isError"]
      assert_match(/not found/i, tool_payload(reply)["error"])
    end
  end

  test "a malformed body is a parse error rather than a crash" do
    post "/mcp", params: "{not json", headers: auth_headers

    assert_response :bad_request
    assert_equal(-32700, JSON.parse(response.body)["error"]["code"])
  end

  test "a batch from an older client is answered as a batch" do
    replies = rpc([
      { jsonrpc: "2.0", id: 1, method: "ping" },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/list" }
    ])

    assert_response :success
    # The notification contributes no reply, so two go back, not three.
    assert_equal [ 1, 2 ], replies.map { |r| r["id"] }
  end

  test "the endpoint says plainly that it has no stream to GET" do
    get "/mcp"
    assert_response :method_not_allowed
    assert_equal "POST", response.headers["Allow"]
  end

  test "a leg HCB no longer has is dropped, and the match reports what it now pairs" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

    @client.remove_transaction("txn_out")

    with_hcb("reader") do
      listed = tool_payload(call_tool("list_matches", { "organization_id" => "org_1" }))
      reported = listed["matches"].sole

      # The leg is gone from the match, and the discrepancy is what the
      # remaining one comes to -- so it now reports as unbalanced rather than
      # claiming to balance against a transaction HCB doesn't have.
      assert_equal [ "txn_in" ], reported["incoming_ids"]
      assert_empty reported["outgoing_ids"]
      assert_not reported["balanced"]
      assert_empty reported["unresolved_ids"]

      summary = tool_payload(call_tool("get_reconciliation_summary", { "organization_id" => "org_1" }))
      assert_equal 0, summary["matches"]["balanced"]
      assert_equal 1, summary["matches"]["unbalanced"]
      assert_equal 0, summary["matches"]["unresolved"]
    end
  end

  test "matches whose legs all resolve report nothing unresolved" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

    with_hcb("reader") do
      listed = tool_payload(call_tool("list_matches", { "organization_id" => "org_1" }))
      assert_empty listed["matches"].sole["unresolved_ids"]
      assert_equal 0, tool_payload(call_tool("get_reconciliation_summary", { "organization_id" => "org_1" }))["matches"]["unresolved"]
    end
  end
end
