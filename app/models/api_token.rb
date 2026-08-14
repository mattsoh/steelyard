class ApiToken < ApplicationRecord
  # Prefixed so a leaked token is recognizable as this app's in a log or a
  # secret scanner, rather than looking like any other base64 blob. OAuth-issued
  # access tokens carry their own prefix purely so the two are told apart at a
  # glance; authentication treats them identically.
  PREFIX = "sy_".freeze
  OAUTH_PREFIX = "syo_".freeze
  REFRESH_PREFIX = "syr_".freeze

  # How long an OAuth access token lives. Short, because a refresh token backs
  # it: Claude refreshes reactively on a 401 and proactively a few minutes
  # before expiry, so a tight window costs nothing and bounds the damage from a
  # token that leaks out of a client.
  ACCESS_TOKEN_TTL = 1.hour

  # #last_used_at exists to answer "is this token still in use?", which doesn't
  # need per-request precision -- and an MCP client can easily make several
  # requests a second, each of which would otherwise be an extra write.
  LAST_USED_THROTTLE = 5.minutes

  belongs_to :user
  belongs_to :oauth_client, optional: true

  validates :name, presence: true, length: { maximum: 80 }

  scope :active, -> { where(revoked_at: nil) }
  # A token minted by hand never expires; one issued through OAuth does.
  scope :unexpired, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }

  # The secrets, set only on the record that just minted or rotated them -- the
  # digests are all that's stored, so this is the one moment they can be handed
  # out.
  attr_reader :plaintext, :plaintext_refresh_token

  def self.mint!(user:, name:)
    token = new(user: user, name: name.to_s.strip.presence || "API token")
    token.regenerate_access_token(prefix: PREFIX, ttl: nil)
    token.save!
    token
  end

  # An OAuth connection: named for the client that asked, so the tokens page
  # shows "Claude" rather than an opaque row nobody dares revoke.
  def self.mint_for_client!(user:, oauth_client:, scope:)
    token = new(user: user, oauth_client: oauth_client, name: oauth_client.name, scope: scope)
    token.regenerate_access_token(prefix: OAUTH_PREFIX, ttl: ACCESS_TOKEN_TTL)
    token.regenerate_refresh_token
    token.save!
    token
  end

  # SHA-256 rather than bcrypt, deliberately: authentication here is a *lookup*
  # by digest, and a per-record salt would mean rehashing every token in the
  # table on every API request. What makes bcrypt worth its cost is that human
  # passwords are guessable; these are 256 bits of CSPRNG output, so there's no
  # dictionary for a fast hash to expose.
  def self.digest(plaintext) = OpenSSL::Digest::SHA256.hexdigest(plaintext.to_s)

  def self.authenticate(plaintext)
    return nil if plaintext.blank?

    active.unexpired.find_by(token_digest: digest(plaintext))
  end

  def self.find_by_refresh_token(plaintext)
    return nil if plaintext.blank?

    # Deliberately not scoped to #unexpired: the access token is expected to be
    # expired by the time a refresh arrives. Revocation still applies.
    active.find_by(refresh_token_digest: digest(plaintext))
  end

  # Rotates both secrets together, which is what OAuth 2.1 asks of a public
  # client: the refresh token that bought this response is dead the moment the
  # response is written.
  def refresh!
    regenerate_access_token(prefix: OAUTH_PREFIX, ttl: ACCESS_TOKEN_TTL)
    regenerate_refresh_token
    save!
    self
  end

  def regenerate_access_token(prefix:, ttl:)
    @plaintext = prefix + SecureRandom.urlsafe_base64(32)
    self.token_digest = self.class.digest(@plaintext)
    self.expires_at = ttl && ttl.from_now
  end

  def regenerate_refresh_token
    @plaintext_refresh_token = REFRESH_PREFIX + SecureRandom.urlsafe_base64(32)
    self.refresh_token_digest = self.class.digest(@plaintext_refresh_token)
  end

  def expires_in = expires_at && (expires_at - Time.current).round

  def oauth? = oauth_client_id.present?

  def touch_last_used!
    return if last_used_at.present? && last_used_at > LAST_USED_THROTTLE.ago

    update_column(:last_used_at, Time.current)
  end

  def revoke! = update!(revoked_at: Time.current)

  def revoked? = revoked_at.present?
end
