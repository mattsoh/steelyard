class MatchAdjustment < ApplicationRecord
  include Auditable

  belongs_to :match, inverse_of: :adjustments
  belongs_to :created_by, class_name: "User", foreign_key: :created_by_user_id

  validates :amount_cents, presence: true
  validates :memo, presence: true

  # The only model here without its own copy of the org id, so the version
  # takes it from the match this adjusts.
  def audited_organization_id = match&.hcb_organization_id
end
