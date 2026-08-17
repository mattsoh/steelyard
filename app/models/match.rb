class Match < ApplicationRecord
  include Auditable

  belongs_to :created_by, class_name: "User", foreign_key: :created_by_user_id, inverse_of: :created_matches
  belongs_to :undone_by, class_name: "User", foreign_key: :undone_by_user_id, inverse_of: :undone_matches, optional: true
  belongs_to :hidden_by, class_name: "User", foreign_key: :hidden_by_user_id, inverse_of: :hidden_matches, optional: true

  has_many :match_transactions, inverse_of: :match, dependent: :destroy
  has_many :adjustments, class_name: "MatchAdjustment", inverse_of: :match, dependent: :destroy

  validates :hcb_organization_id, presence: true

  scope :active, -> { where(undone_at: nil) }
  scope :visible, -> { where(hidden_at: nil) }
  scope :for_organization, ->(org_id) { where(hcb_organization_id: org_id) }

  def undone? = undone_at.present?

  # Hidden is presentation, not state: the match still pairs what it pairs and
  # still carries its discrepancy, it just doesn't sit in the matcher's lists
  # unless someone asks to see the hidden ones. Every API that lists matches
  # still returns it, flagged.
  def hidden? = hidden_at.present?

  # Filters in Ruby rather than `match_transactions.active.incoming.pluck`,
  # which would issue a fresh query per call regardless of `includes`/prior
  # loading -- callers that preload, or just built :match_transactions (e.g.
  # right after Matches::Create), get this for free with no N+1 per match.
  #
  # Undoing a match marks every leg undone alongside it, so an undone match has
  # no live legs at all and these would go empty -- which is no answer for the
  # one view that exists to explain what happened to it. A leg is only ever
  # undone together with its match, so reading undone legs back on an undone
  # match is the same set, and leaves every other caller unchanged.
  def incoming_transaction_ids(include_undone: undone?)
    leg_ids(:incoming?, include_undone)
  end

  def outgoing_transaction_ids(include_undone: undone?)
    leg_ids(:outgoing?, include_undone)
  end

  private

  def leg_ids(direction, include_undone)
    match_transactions.select { |mt| (include_undone || mt.undone_at.nil?) && mt.public_send(direction) }.map(&:hcb_transaction_id)
  end
end
