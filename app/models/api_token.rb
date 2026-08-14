class ApiToken < ApplicationRecord
  # Prefixed so a leaked token is recognizable as this app's in a log or a
  # secret scanner, rather than looking like any other base64 blob.
  PREFIX = "sy_".freeze

  # #last_used_at exists to answer "is this token still in use?", which doesn't
  # need per-request precision -- and an MCP client can easily make several
  # requests a second, each of which would otherwise be an extra write.
  LAST_USED_THROTTLE = 5.minutes

  belongs_to :user

  validates :name, presence: true, length: { maximum: 80 }

  scope :active, -> { where(revoked_at: nil) }

  # The token itself, set only on the record that just minted it -- the digest
  # is all that's stored, so this is the one moment it can be shown.
  attr_reader :plaintext

  def self.mint!(user:, name:)
    plaintext = PREFIX + SecureRandom.urlsafe_base64(32)
    token = create!(user: user, name: name.to_s.strip.presence || "API token", token_digest: digest(plaintext))
    token.instance_variable_set(:@plaintext, plaintext)
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

    active.find_by(token_digest: digest(plaintext))
  end

  def touch_last_used!
    return if last_used_at.present? && last_used_at > LAST_USED_THROTTLE.ago

    update_column(:last_used_at, Time.current)
  end

  def revoke! = update!(revoked_at: Time.current)

  def revoked? = revoked_at.present?
end
