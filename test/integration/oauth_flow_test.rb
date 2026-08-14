require "test_helper"

# The whole connector dance, in the order a Claude custom connector performs it:
# discovery -> register -> authorize (log in, consent) -> exchange -> call MCP
# -> refresh.
class OauthFlowTest < ActionDispatch::IntegrationTest
  CLAUDE_CALLBACK = "https://claude.ai/api/mcp/auth_callback".freeze

  def setup
    @user = User.create!(hcb_user_id: "usr_1", name: "Matt", email: "matt@example.com",
                         access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(@verifier), padding: false)
  end

  def body = JSON.parse(response.body)

  def register_client(redirect_uris: [ CLAUDE_CALLBACK ], **extra)
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: redirect_uris, **extra }.to_json,
         headers: { "Content-Type" => "application/json" }
    body
  end

  def authorize_params(client_id, overrides = {})
    {
      response_type: "code", client_id: client_id, redirect_uri: CLAUDE_CALLBACK,
      code_challenge: @challenge, code_challenge_method: "S256",
      scope: "mcp offline_access", state: "st4te"
    }.merge(overrides)
  end

  # Runs the authorize + consent leg with a signed-in session, and returns the
  # code Claude would have received on the callback.
  def approve_and_capture_code(client_id, overrides = {})
    get "/oauth/authorize", params: authorize_params(client_id, overrides)
    assert_response :success

    post "/oauth/authorize", params: authorize_params(client_id, overrides).merge(approve: "Approve")
    assert_response :redirect
    redirect = URI.parse(response.headers["Location"])
    Rack::Utils.parse_query(redirect.query)
  end

  def exchange(client_id, code, overrides = {})
    post "/oauth/token", params: {
      grant_type: "authorization_code", code: code, client_id: client_id,
      redirect_uri: CLAUDE_CALLBACK, code_verifier: @verifier
    }.merge(overrides)
    body
  end

  test "an unauthenticated MCP request points the client at the metadata" do
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
    challenge = response.headers["WWW-Authenticate"]
    assert_match %r{resource_metadata="http://www\.example\.com/\.well-known/oauth-protected-resource"}, challenge
    assert_match(/scope="mcp offline_access"/, challenge)
  end

  test "the discovery documents describe this server" do
    get "/.well-known/oauth-protected-resource"
    assert_response :success
    assert_equal "http://www.example.com/mcp", body["resource"]
    assert_equal [ "http://www.example.com" ], body["authorization_servers"]

    # Clients probe the path-suffixed variant first; it has to answer too.
    get "/.well-known/oauth-protected-resource/mcp"
    assert_response :success

    get "/.well-known/oauth-authorization-server"
    assert_response :success
    assert_equal "http://www.example.com/oauth/authorize", body["authorization_endpoint"]
    assert_equal "http://www.example.com/oauth/register", body["registration_endpoint"]
    # Required, and clients check it before starting.
    assert_equal [ "S256" ], body["code_challenge_methods_supported"]
    assert_includes body["token_endpoint_auth_methods_supported"], "none"
    assert_includes body["grant_types_supported"], "refresh_token"
  end

  test "a client can register itself as a public client" do
    registered = register_client
    assert_response :created

    assert registered["client_id"].present?
    assert_nil registered["client_secret"]
    assert_equal "none", registered["token_endpoint_auth_method"]
    assert_equal [ CLAUDE_CALLBACK ], registered["redirect_uris"]
  end

  test "a client that asks to authenticate with a secret is given one" do
    registered = register_client(token_endpoint_auth_method: "client_secret_post")
    assert registered["client_secret"].present?
    assert_equal "client_secret_post", registered["token_endpoint_auth_method"]
  end

  test "registration refuses a redirect target that isn't safe to send a code to" do
    register_client(redirect_uris: [ "http://evil.example.com/callback" ])
    assert_response :bad_request
    assert_equal "invalid_redirect_uri", body["error"]

    register_client(redirect_uris: [])
    assert_response :bad_request
  end

  test "registration rejects a body that isn't a JSON object" do
    post "/oauth/register", params: "[]", headers: { "Content-Type" => "application/json" }
    assert_response :bad_request
    assert_equal "invalid_client_metadata", body["error"]
  end

  test "the consent screen requires signing in first, and comes back to itself" do
    client_id = register_client["client_id"]

    get "/oauth/authorize", params: authorize_params(client_id)

    assert_redirected_to root_path
    # Parked so the HCB callback can return the user to the request the client
    # sent them here with -- nobody could retype it.
    parked = URI.parse(session[:return_to])
    assert_equal "/oauth/authorize", parked.path
    assert_equal authorize_params(client_id).stringify_keys, Rack::Utils.parse_query(parked.query)
  end

  test "the full flow issues a token that works on the MCP endpoint" do
    client_id = register_client["client_id"]
    sign_in!

    returned = approve_and_capture_code(client_id)
    assert_equal "st4te", returned["state"]
    assert returned["code"].present?

    tokens = exchange(client_id, returned["code"])
    assert_response :success
    assert_equal "Bearer", tokens["token_type"]
    assert_equal "mcp offline_access", tokens["scope"]
    assert_in_delta ApiToken::ACCESS_TOKEN_TTL.to_i, tokens["expires_in"], 5
    assert tokens["refresh_token"].present?
    assert_equal "no-store", response.headers["Cache-Control"]

    # The token acts as the person who approved it.
    get "/api/v1/me", headers: { "Authorization" => "Bearer #{tokens["access_token"]}" }
    assert_response :success
    assert_equal "usr_1", body["user"]["hcb_user_id"]

    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
         headers: { "Authorization" => "Bearer #{tokens["access_token"]}", "Content-Type" => "application/json" }
    assert_response :success
    assert body["result"]["tools"].any?
  end

  test "denying sends the client an error instead of a code" do
    client_id = register_client["client_id"]
    sign_in!

    get "/oauth/authorize", params: authorize_params(client_id)
    post "/oauth/authorize", params: authorize_params(client_id).merge(deny: "Deny")

    returned = Rack::Utils.parse_query(URI.parse(response.headers["Location"]).query)
    assert_equal "access_denied", returned["error"]
    assert_equal "st4te", returned["state"]
    assert_nil returned["code"]
  end

  test "an unregistered client or redirect target is shown to the user, never redirected" do
    sign_in!

    get "/oauth/authorize", params: authorize_params("not-a-client")
    assert_response :bad_request
    assert_match(/registered with Steelyard/, response.body)

    client_id = register_client["client_id"]
    get "/oauth/authorize", params: authorize_params(client_id, redirect_uri: "https://evil.example.com/steal")
    assert_response :bad_request
    assert_match(/registered to receive replies/, response.body)
  end

  test "a request without PKCE is refused" do
    client_id = register_client["client_id"]
    sign_in!

    get "/oauth/authorize", params: authorize_params(client_id, code_challenge: "", code_challenge_method: "")
    returned = Rack::Utils.parse_query(URI.parse(response.headers["Location"]).query)
    assert_equal "invalid_request", returned["error"]

    get "/oauth/authorize", params: authorize_params(client_id, response_type: "token")
    returned = Rack::Utils.parse_query(URI.parse(response.headers["Location"]).query)
    assert_equal "unsupported_response_type", returned["error"]
  end

  test "the exchange checks the verifier, the redirect and the client" do
    client_id = register_client["client_id"]
    other_client = register_client["client_id"]
    sign_in!

    code = approve_and_capture_code(client_id)["code"]
    assert_equal "invalid_grant", exchange(client_id, code, code_verifier: "wrong-verifier")["error"]
    assert_equal "invalid_grant", exchange(client_id, code, redirect_uri: "https://claude.ai/other")["error"]
    assert_equal "invalid_grant", exchange(other_client, code)["error"]

    # None of those consumed the code, so the honest exchange still works.
    assert exchange(client_id, code)["access_token"].present?
  end

  test "a replayed code revokes the token it already bought" do
    client_id = register_client["client_id"]
    sign_in!

    code = approve_and_capture_code(client_id)["code"]
    first = exchange(client_id, code)
    assert first["access_token"].present?

    replayed = exchange(client_id, code)
    assert_equal "invalid_grant", replayed["error"]

    get "/api/v1/me", headers: { "Authorization" => "Bearer #{first["access_token"]}" }
    assert_response :unauthorized
  end

  test "an expired code is refused" do
    client_id = register_client["client_id"]
    sign_in!

    code = approve_and_capture_code(client_id)["code"]
    OauthAuthorizationCode.last.update!(expires_at: 1.second.ago)

    assert_equal "invalid_grant", exchange(client_id, code)["error"]
  end

  test "refreshing rotates both secrets and keeps the connection working" do
    client_id = register_client["client_id"]
    sign_in!
    tokens = exchange(client_id, approve_and_capture_code(client_id)["code"])

    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: tokens["refresh_token"], client_id: client_id }
    assert_response :success
    refreshed = body
    assert_not_equal tokens["access_token"], refreshed["access_token"]
    assert_not_equal tokens["refresh_token"], refreshed["refresh_token"]

    get "/api/v1/me", headers: { "Authorization" => "Bearer #{refreshed["access_token"]}" }
    assert_response :success

    # The old refresh token is spent, and the old access token went with it.
    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: tokens["refresh_token"], client_id: client_id }
    assert_equal "invalid_grant", body["error"]

    get "/api/v1/me", headers: { "Authorization" => "Bearer #{tokens["access_token"]}" }
    assert_response :unauthorized
  end

  test "an expired access token is refused, and says where to refresh" do
    client_id = register_client["client_id"]
    sign_in!
    tokens = exchange(client_id, approve_and_capture_code(client_id)["code"])
    ApiToken.last.update!(expires_at: 1.second.ago)

    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
         headers: { "Authorization" => "Bearer #{tokens["access_token"]}", "Content-Type" => "application/json" }

    assert_response :unauthorized
    assert_match(/resource_metadata=/, response.headers["WWW-Authenticate"])
  end

  test "revoking a connection from the tokens page cuts the client off" do
    client_id = register_client["client_id"]
    sign_in!
    tokens = exchange(client_id, approve_and_capture_code(client_id)["code"])

    connection = ApiToken.find_by(oauth_client: OauthClient.find_by(client_id: client_id))
    assert_equal "Claude", connection.name
    delete api_token_path(connection)

    get "/api/v1/me", headers: { "Authorization" => "Bearer #{tokens["access_token"]}" }
    assert_response :unauthorized

    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: tokens["refresh_token"], client_id: client_id }
    assert_equal "invalid_grant", body["error"]
  end

  test "unsupported grant types are named as such" do
    post "/oauth/token", params: { grant_type: "client_credentials", client_id: "x" }
    assert_response :bad_request
    assert_equal "unsupported_grant_type", body["error"]
  end

  test "a confidential client must present its secret" do
    registered = register_client(token_endpoint_auth_method: "client_secret_post")
    client_id = registered["client_id"]
    sign_in!
    code = approve_and_capture_code(client_id)["code"]

    assert_equal "invalid_client", exchange(client_id, code)["error"]
    assert_response :unauthorized

    assert exchange(client_id, code, client_secret: registered["client_secret"])["access_token"].present?
  end

  test "a native client's loopback redirect matches whatever port it got" do
    client_id = register_client(redirect_uris: [ "http://127.0.0.1/callback", "http://localhost/callback" ])["client_id"]
    sign_in!

    landing = "http://127.0.0.1:53119/callback"
    get "/oauth/authorize", params: authorize_params(client_id, redirect_uri: landing)
    assert_response :success

    post "/oauth/authorize", params: authorize_params(client_id, redirect_uri: landing).merge(approve: "Approve")
    assert_response :redirect
    assert response.headers["Location"].start_with?(landing)
  end

  private

  def sign_in! = sign_in_via_hcb!(@user)
end
