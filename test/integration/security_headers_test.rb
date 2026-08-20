require "test_helper"

# The Content-Security-Policy is the backstop under the frontend's escaping (see
# config/initializers/content_security_policy.rb). It only works if every inline
# script the app serves carries the response's nonce -- an inline script without
# one silently stops running under the policy, which is a broken page rather
# than a caught attack, so the nonce plumbing is worth a test of its own.
class SecurityHeadersTest < ActionDispatch::IntegrationTest
  def csp = response.headers["Content-Security-Policy"].to_s

  def header_nonce = csp[/script-src [^;]*'nonce-([^']+)'/, 1]

  test "the policy is served and locks down the directives an injection would need" do
    get root_path

    assert_response :success
    assert_includes csp, "default-src 'self'"
    assert_includes csp, "object-src 'none'"
    assert_includes csp, "base-uri 'self'"
    assert_includes csp, "connect-src 'self'"
    # Nothing here is meant to be framed -- least of all the OAuth consent
    # screen, whose whole job is to be read before a button is pressed.
    assert_includes csp, "frame-ancestors 'none'"
  end

  test "the importmap's inline scripts carry the response's nonce" do
    get root_path

    nonce = header_nonce
    assert nonce.present?, "expected a nonce in script-src, got: #{csp}"
    assert_select "script[type=importmap][nonce=?]", nonce
    assert_select "script[type=module][nonce=?]", nonce
  end

  # The legacy pages set their organization globals from an inline script in
  # their own layout, which every one of their JS bundles reads. Under the policy
  # that script runs only if it's nonced.
  test "the legacy layout's bootstrap script carries the response's nonce" do
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b",
                        token_expires_at: 1.hour.from_now)
    sign_in_via_hcb!(user)

    stub_membership("member") do
      get organization_matcher_path(organization_id: "org_1")
    end

    assert_response :success
    nonce = header_nonce
    assert nonce.present?, "expected a nonce in script-src, got: #{csp}"
    assert_match(/<script nonce="#{Regexp.escape(nonce)}">\s*window\.HCB_ORGANIZATION_ID/, response.body)
  end

  # A per-response nonce is only a nonce if it isn't the same one twice.
  test "the nonce differs between responses" do
    get root_path
    first = header_nonce
    get root_path

    assert first.present?
    assert_not_equal first, header_nonce
  end
end
