require "test_helper"

# Where an authorization code is allowed to be delivered. Worth its own test:
# every other check in the flow is moot if a code can be sent somewhere the
# client never registered.
class Oauth::RedirectUriTest < ActiveSupport::TestCase
  test "https anywhere, http only back to the machine that registered it" do
    assert Oauth::RedirectUri.registerable?("https://claude.ai/api/mcp/auth_callback")
    assert Oauth::RedirectUri.registerable?("http://127.0.0.1/callback")
    assert Oauth::RedirectUri.registerable?("http://localhost:3000/callback")

    assert_not Oauth::RedirectUri.registerable?("http://evil.example.com/callback")
    assert_not Oauth::RedirectUri.registerable?("ftp://example.com/callback")
    assert_not Oauth::RedirectUri.registerable?("not a uri at all")
    assert_not Oauth::RedirectUri.registerable?("")
    # A fragment can carry a token past the server that issued it.
    assert_not Oauth::RedirectUri.registerable?("https://claude.ai/cb#fragment")
  end

  test "a registered URI matches only itself" do
    registered = [ "https://claude.ai/api/mcp/auth_callback" ]

    assert Oauth::RedirectUri.permitted?(registered, "https://claude.ai/api/mcp/auth_callback")
    assert_not Oauth::RedirectUri.permitted?(registered, "https://claude.ai/api/mcp/auth_callback/../elsewhere")
    assert_not Oauth::RedirectUri.permitted?(registered, "https://claude.ai.evil.com/api/mcp/auth_callback")
    assert_not Oauth::RedirectUri.permitted?(registered, "https://claude.ai/api/mcp/auth_callback?extra=1")
    assert_not Oauth::RedirectUri.permitted?(registered, nil)
  end

  # RFC 8252 §7.3: a native client can't know which port it will get, so the
  # port is ignored for loopback -- and only for loopback.
  test "a loopback URI matches on any port, but nothing else moves" do
    registered = [ "http://127.0.0.1/callback", "http://localhost/callback" ]

    assert Oauth::RedirectUri.permitted?(registered, "http://127.0.0.1:53119/callback")
    assert Oauth::RedirectUri.permitted?(registered, "http://localhost:8080/callback")

    assert_not Oauth::RedirectUri.permitted?(registered, "http://127.0.0.1:53119/somewhere-else")
    assert_not Oauth::RedirectUri.permitted?(registered, "https://127.0.0.1:53119/callback")
    assert_not Oauth::RedirectUri.permitted?(registered, "http://127.0.0.2:53119/callback")
    assert_not Oauth::RedirectUri.permitted?(registered, "http://evil.example.com:53119/callback")
    # The port carve-out must not become a free pass for a different host that
    # merely registered a loopback URI.
    assert_not Oauth::RedirectUri.permitted?([ "https://claude.ai/cb" ], "http://127.0.0.1:9/cb")
  end
end
