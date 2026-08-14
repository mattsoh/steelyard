# An OAuth client that may ask Steelyard users for access. Claude registers one
# of these for itself on every fresh connection (RFC 7591 dynamic client
# registration), which is why registration is open -- a client record on its own
# grants nothing at all until a signed-in user approves it on the consent
# screen, and what it can then do is bounded by that user's HCB membership.
class OauthClient < ApplicationRecord
  has_many :api_tokens, dependent: :nullify
  has_many :oauth_authorization_codes, dependent: :destroy

  validates :client_id, presence: true, uniqueness: true
  validates :name, presence: true
  validate :redirect_uris_are_usable

  def self.register!(name:, redirect_uris:, secret: nil)
    create!(
      client_id: SecureRandom.uuid,
      name: name.to_s.strip.presence || "Unnamed client",
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

    redirect_uris.each do |uri|
      errors.add(:redirect_uris, "#{uri} is not a usable redirect URI") unless Oauth::RedirectUri.registerable?(uri)
    end
  end
end
