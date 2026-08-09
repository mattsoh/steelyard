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

  # One HCB page at a time, so the frontend can render rows as they arrive
  # instead of blocking on the full drain #index needs for cutoff filtering.
  def page
    result = Hcb::OrganizationTransactions.new(hcb_client, organization_id)
      .fetch_page(stream_id: params[:stream_id].to_s, after: params[:after].presence)

    render json: {
      rows: result[:data].map { |t| Hcb::TransactionPresenter.new(t).as_json },
      has_more: result[:has_more],
      next_after: result[:next_after],
      total_count: result[:total_count]
    }
  end

  # Cheap "did anything land on HCB since we last drained?" check -- see
  # Hcb::OrganizationTransactions#sync_head!. Costs one HCB request, and in the
  # common case (a handful of new transactions) that same request also *fixes*
  # the cache, so the caller can just re-read #index. When more changed than a
  # single page can account for, the full redrain is handed to a background job
  # rather than paid for inline: the caller already has usable data on screen
  # and can keep working with it, polling #sync_status to learn when the fresh
  # drain lands.
  #
  # Deliberately available to readers as well as matchers: it only refreshes
  # cached HCB data everyone on the page is already allowed to see.
  def refresh
    transactions = Hcb::OrganizationTransactions.new(hcb_client, organization_id)
    status = transactions.sync_head!
    WarmOrganizationTransactionsJob.perform_later(current_user.id, organization_id) if status == :deep

    render json: { status: status, **transactions.sync_state }
  end

  # Progress poll for the background redrain #refresh hands off. Reads local
  # cache only -- never HCB -- so polling it every few seconds can't eat into
  # the org-shared rate limit Hcb::OrganizationTransactions exists to protect.
  def sync_status
    render json: Hcb::OrganizationTransactions.new(hcb_client, organization_id).sync_state
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
