class User < ApplicationRecord
  encrypts :access_token, :refresh_token

  has_many :api_tokens, dependent: :destroy
  has_many :created_matches, class_name: "Match", foreign_key: :created_by_user_id, inverse_of: :created_by
  has_many :undone_matches, class_name: "Match", foreign_key: :undone_by_user_id, inverse_of: :undone_by

  validates :hcb_user_id, presence: true, uniqueness: true

  def token_fresh?(buffer: 60.seconds)
    token_expires_at.present? && token_expires_at > buffer.from_now
  end
end
