# The short-lived code handed back through the browser after a user approves a
# client, and exchanged once for a token. Everything the exchange has to match
# is pinned here at issue time -- client, redirect URI, PKCE challenge, scope --
# so a code intercepted in transit is worthless to anyone who can't also prove
# they started the flow.
class OauthAuthorizationCode < ApplicationRecord
  # Long enough for a browser redirect and a token request over a bad
  # connection, short enough that a code left in a proxy log is dead.
  TTL = 5.minutes

  belongs_to :oauth_client
  belongs_to :user
  belongs_to :api_token, optional: true

  attr_reader :plaintext

  def self.issue!(client:, user:, redirect_uri:, code_challenge:, scope:, resource: nil)
    code = new(
      oauth_client: client, user: user, redirect_uri: redirect_uri,
      code_challenge: code_challenge, scope: scope, resource: resource,
      expires_at: TTL.from_now
    )
    plaintext = SecureRandom.urlsafe_base64(32)
    code.code_digest = ApiToken.digest(plaintext)
    code.save!
    code.instance_variable_set(:@plaintext, plaintext)
    code
  end

  def self.find_by_plaintext(plaintext)
    return nil if plaintext.blank?

    find_by(code_digest: ApiToken.digest(plaintext))
  end

  def usable? = consumed_at.nil? && expires_at > Time.current

  def consumed? = consumed_at.present?

  # PKCE, S256 only: proof that whoever is redeeming the code is the same party
  # that started the flow, which is what stops a stolen code being usable.
  def verifier_matches?(code_verifier)
    return false if code_verifier.blank?

    expected = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(code_verifier), padding: false)
    ActiveSupport::SecurityUtils.secure_compare(code_challenge.to_s, expected)
  end
end
