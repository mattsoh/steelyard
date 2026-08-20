require "test_helper"

# Registration is open (RFC 7591 -- Claude registers a client for itself on every
# fresh connection), so everything on a client record arrived unauthenticated.
# The name is the part a person then reads on the consent screen as the identity
# of whoever is asking.
class OauthClientTest < ActiveSupport::TestCase
  CALLBACK = "https://claude.ai/api/mcp/auth_callback".freeze

  test "a name too long to be a name is cut down to one" do
    long = "Steelyard Official -- approved by Hack Club. " \
           "Your session expired; click Approve to continue and keep your matches."
    client = OauthClient.register!(name: long, redirect_uris: [ CALLBACK ])

    assert_equal OauthClient::MAX_NAME_LENGTH, client.name.length
    assert client.valid?
  end

  # A token minted for a client is named after it (ApiToken#mint_for_client!,
  # whose name is capped at 80), so a name over the limit used to take the whole
  # token exchange down with it at the very end of the flow.
  test "a truncated name still fits the token minted for the client" do
    client = OauthClient.register!(name: "x" * 500, redirect_uris: [ CALLBACK ])
    user = User.create!(hcb_user_id: "usr_name_cap", access_token: "a", refresh_token: "b",
                        token_expires_at: 1.hour.from_now)

    token = ApiToken.mint_for_client!(user: user, oauth_client: client, scope: "mcp")

    assert token.persisted?
    assert_equal client.name, token.name
  end

  test "an unbounded list of redirect URIs is rejected" do
    uris = Array.new(OauthClient::MAX_REDIRECT_URIS + 1) { |i| "https://example.com/cb/#{i}" }

    assert_raises ActiveRecord::RecordInvalid do
      OauthClient.register!(name: "Greedy", redirect_uris: uris)
    end
  end

  test "a list at the limit is still accepted" do
    uris = Array.new(OauthClient::MAX_REDIRECT_URIS) { |i| "https://example.com/cb/#{i}" }

    assert OauthClient.register!(name: "Fine", redirect_uris: uris).persisted?
  end
end
