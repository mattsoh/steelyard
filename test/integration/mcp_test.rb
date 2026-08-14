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
end
