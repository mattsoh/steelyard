# An OAuth client that may ask Steelyard users for access. Claude registers one
# of these for itself on every fresh connection (RFC 7591 dynamic client
# registration), which is why registration is open -- a client record on its own
# grants nothing at all until a signed-in user approves it on the consent
# screen, and what it can then do is bounded by that user's HCB membership.
class OauthClient < ApplicationRecord
  has_many :api_tokens, dependent: :nullify
  has_many :oauth_authorization_codes, dependent: :destroy

  # A name nobody registered, and a name too long to read, are the same problem:
  # this string is shown to a person on the consent screen as the identity of
  # whoever is asking, and registration is open to anyone. A paragraph of
  # reassuring prose in place of a name ("Steelyard Official -- approved, click
  # Approve to continue") is the cheap version of that attack, so the field is
  # held to the length of a name. It also can't outgrow ApiToken's own limit,
  # since a token minted for this client is named after it.
  MAX_NAME_LENGTH = 80

  # Enough for a client that registers several loopback ports or environments,
  # short of an unbounded write through an unauthenticated endpoint.
  MAX_REDIRECT_URIS = 10

  validates :client_id, presence: true, uniqueness: true
  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
  validate :redirect_uris_are_usable

  def self.register!(name:, redirect_uris:, secret: nil)
    create!(
      client_id: SecureRandom.uuid,
      # Truncated rather than rejected: a client whose software_id happens to be
      # long is being honest and should still connect. The cap is what stops the
      # field being used as a message; see MAX_NAME_LENGTH.
      name: name.to_s.strip.truncate(MAX_NAME_LENGTH).presence || "Unnamed client",
      redirect_uris: Array(redirect_uris).map(&:to_s),
      secret_digest: secret && ApiToken.digest(secret)
    )
  end

  def public_client? = secret_digest.blank?

  def authenticates_with?(secret)
    return true if public_client?

    secret.present? && ActiveSupport::SecurityUtils.secure_compare(secret_digest, ApiToken.digest(secret))
  end

  def permits_redirect?(candidate) = Oauth::RedirectUri.permitted?(redirect_uris, candidate)

  private

  # A redirect target is where the authorization code is delivered, so an
  # attacker-controlled one is the whole ballgame. https anywhere; plain http
  # only back to the registering machine itself, which is how a native client
  # like Claude Code receives its code (RFC 8252).
  def redirect_uris_are_usable
    return errors.add(:redirect_uris, "must include at least one URI") if redirect_uris.blank?
    return errors.add(:redirect_uris, "may list at most #{MAX_REDIRECT_URIS} URIs") if redirect_uris.size > MAX_REDIRECT_URIS

    redirect_uris.each do |uri|
      errors.add(:redirect_uris, "#{uri} is not a usable redirect URI") unless Oauth::RedirectUri.registerable?(uri)
    end
  end
end
