class Api::TransactionsController < ApplicationController
  include OrganizationScoped
  include RawJsonRendering

  # The matcher's working set: transactions after the zero-balance cutoff,
  # plus anything referenced by a still-visible match (which may predate the
  # cutoff -- app.js needs those rows in its byId map to render match legs;
  # they never appear in the unmatched lists because they're already used).
  #
  # Assembled from strings rather than built as a Hash and handed to #to_json:
  # the rows come out of the drain's presentation cache already serialized (see
  # Hcb::OrganizationTransactions#presented), so parsing them back into Ruby
  # objects just to re-generate the identical JSON is work this endpoint --
  # the heaviest read in the app -- does not have to do.
  def index
    ledger = OrganizationLedger.new(hcb_client, organization_id)
    cutoff = ledger.effective_cutoff
    ids = (ledger.after_cutoff_ids + referenced_by_visible_matches(ledger)).uniq

    render json: json_object(
      zero_balance_date: cutoff&.date.to_json,
      zero_balance_selected_id: cutoff&.transaction_id.to_json,
      zero_balance_options: ledger.zero_options.map { |o| { date: o.date, transaction_id: o.transaction_id, beginning: o.beginning? } }.to_json,
      transactions: "[#{ledger.transaction_fragments(ids).join(',')}]"
    )
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

  # Re-checks ONE transaction against HCB, for the detail modal. #refresh only
  # ever looks at the newest page and a redrain only re-fetches its recent
  # window, so a transaction older than that which changed on HCB (a pending
  # charge that settled differently, a reversal) can't be re-checked any other
  # way short of the full reload below. Costs a single HCB request.
  #
  # Answers with both the old and new copy so the caller can say what actually
  # changed, plus any match whose discrepancy moved as a result -- a leg
  # changing amount is exactly the case where a match saved as balanced isn't
  # balanced any more.
  def refresh_one
    result = Hcb::OrganizationTransactions.new(hcb_client, organization_id).refresh_one!(params[:id])
    return render json: { error: "That transaction isn't part of this organization's history." }, status: :not_found if result.nil?

    render json: {
      previous: Hcb::TransactionPresenter.new(result.previous).as_json,
      transaction: Hcb::TransactionPresenter.new(result.current).as_json,
      matches_changed: resync_matches_for(params[:id])
    }
  rescue OAuth2::Error => e
    raise unless e.response.status == 404

    render json: { error: "HCB no longer has that transaction." }, status: :not_found
  end

  # Full-history redrain, on explicit request -- one HCB request per 100
  # transactions of the org's *entire* history, against a rate limit shared by
  # everyone using this app, which is why the UI warns first. Handed to the
  # background job rather than run inline (the drain outlives any reasonable
  # request timeout on a large org) and claimed under a lock, so two people
  # asking at once still only costs one drain. Either way the caller polls
  # #sync_status and reloads when a newer drain lands.
  def reload
    transactions = Hcb::OrganizationTransactions.new(hcb_client, organization_id)
    claimed = transactions.claim_full_reload!
    WarmOrganizationTransactionsJob.perform_later(current_user.id, organization_id, full: true) if claimed

    render json: { status: claimed ? "started" : "already_running", **transactions.sync_state }
  end

  # Progress poll for the background redrain #refresh hands off. Reads local
  # cache only -- never HCB -- so polling it every few seconds can't eat into
  # the org-shared rate limit Hcb::OrganizationTransactions exists to protect.
  def sync_status
    render json: Hcb::OrganizationTransactions.new(hcb_client, organization_id).sync_state
  end

  private

  # Re-derives the discrepancy of every active match this transaction is a leg
  # of, now that its amount may have moved, and reports the ones that changed so
  # the frontend can tell the user their match no longer balances (and re-render
  # it into the right bucket). Built after the splice above, so the ledger reads
  # the refreshed value.
  def resync_matches_for(transaction_id)
    match_ids = MatchTransaction.active
      .where(hcb_organization_id: organization_id, hcb_transaction_id: transaction_id)
      .select(:match_id)
    matches = Match.active.for_organization(organization_id)
      .where(id: match_ids).includes(:match_transactions, :adjustments)

    Matches::Resync.new(ledger: OrganizationLedger.new(hcb_client, organization_id), matches: matches).call
      .map { |change| { id: change.match.id, from: change.from_cents / 100.0, to: change.to_cents / 100.0 } }
  end

  # Ids only: whether each one can be resolved at all is settled by
  # OrganizationLedger#transaction_fragments, which has to look them up anyway.
  def referenced_by_visible_matches(ledger)
    MatchTransaction.active.where(hcb_organization_id: organization_id)
      .pluck(:match_id, :hcb_transaction_id)
      .group_by(&:first)
      .values
      .map { |pairs| pairs.map(&:last) }
      .reject { |ids| ledger.classify(ids) == :hidden }
      .flatten
  end
end
