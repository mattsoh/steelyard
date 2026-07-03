class Api::TransactionsController < ApplicationController
  include OrganizationScoped

  # The matcher's working set: transactions after the zero-balance cutoff,
  # plus anything referenced by a still-visible match (which may predate the
  # cutoff -- app.js needs those rows in its byId map to render match legs;
  # they never appear in the unmatched lists because they're already used).
  def index
    ledger = OrganizationLedger.new(hcb_client, organization_id)
    transactions = (ledger.after_cutoff + referenced_by_visible_matches(ledger)).uniq(&:id)

    render json: {
      zero_balance_date: ledger.effective_cutoff&.date,
      zero_balance_selected_id: ledger.effective_cutoff&.transaction_id,
      zero_balance_options: ledger.zero_options.map { |o| { date: o.date, transaction_id: o.transaction_id, beginning: o.beginning? } },
      transactions: transactions.map(&:as_json)
    }
  end

  private

  def referenced_by_visible_matches(ledger)
    MatchTransaction.active.where(hcb_organization_id: organization_id)
      .pluck(:match_id, :hcb_transaction_id)
      .group_by(&:first)
      .values
      .map { |pairs| pairs.map(&:last) }
      .reject { |ids| ledger.classify(ids) == :hidden }
      .flatten
      .filter_map { |id| ledger.transaction_by_id(id) }
  end
end
