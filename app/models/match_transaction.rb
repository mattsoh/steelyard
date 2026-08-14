class MatchTransaction < ApplicationRecord
  include Auditable

  belongs_to :match, inverse_of: :match_transactions

  enum :direction, { incoming: 0, outgoing: 1 }

  validates :hcb_organization_id, :hcb_transaction_id, presence: true

  scope :active, -> { where(undone_at: nil) }
end
