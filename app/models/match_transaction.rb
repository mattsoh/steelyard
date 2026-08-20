class MatchTransaction < ApplicationRecord
  include Auditable

  belongs_to :match, inverse_of: :match_transactions

  enum :direction, { incoming: 0, outgoing: 1 }

  validates :hcb_organization_id, :hcb_transaction_id, presence: true

  # A live leg: one the match currently pairs. `undone_at` is the whole match
  # having been undone; `dropped_at` is this leg alone having stopped being part
  # of it, because HCB no longer accounts for the transaction (see
  # Matches::Resync). A dropped leg is kept rather than deleted so the same
  # transaction coming back can put it straight back in the match.
  scope :active, -> { where(undone_at: nil, dropped_at: nil) }
  scope :dropped, -> { where(undone_at: nil).where.not(dropped_at: nil) }

  def dropped? = dropped_at.present?
  def live? = undone_at.nil? && dropped_at.nil?
end
