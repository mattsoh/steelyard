class Api::TransactionsController < ApplicationController
  include OrganizationScoped
  include RawJsonRendering
  include StreamedTransactionPages

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
      # An organization mid-full-reload has no drain to answer from, so this
      # would otherwise be indistinguishable from one with no transactions.
      reloading: ledger.reloading?.to_json,
      transactions: "[#{ledger.transaction_fragments(ids).join(',')}]"
    )
  end

  # One HCB page at a time, so the frontend can render rows as they arrive
  # instead of blocking on the full drain #index needs for cutoff filtering.
  def page
    render_streamed_page
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
    # :reloading means a full reload is already rebuilding this organization's
    # history from scratch, which subsumes anything this check would ask for --
    # so nothing is queued behind it and the caller just waits for that drain.
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
  # changed, plus anything that happened to the matches this transaction is a
  # leg of -- in the same `match_changes` shape every other surface reports (see
  # Matches::Resync::Result). A leg changing amount is exactly the case where a
  # match saved as balanced isn't balanced any more.
  def refresh_one
    transactions = Hcb::OrganizationTransactions.new(hcb_client, organization_id)
    # Mid-reload there's no drained history to splice a re-fetched transaction
    # into, so this would otherwise report the transaction as not belonging to
    # the organization -- which isn't what happened.
    if transactions.full_reload_running?
      return render json: { error: "A full reload of this organization is running — try again once it finishes." }, status: :conflict
    end

    result = transactions.refresh_one!(params[:id])
    return render json: { error: "That transaction isn't part of this organization's history." }, status: :not_found if result.nil?

    render json: {
      previous: Hcb::TransactionPresenter.new(result.previous).as_json,
      transaction: Hcb::TransactionPresenter.new(result.current).as_json,
      match_changes: resync_matches_for(params[:id])
    }
  rescue OAuth2::Error => e
    raise unless e.response.status == 404

    render json: { error: "HCB no longer has that transaction." }, status: :not_found
  end

  # Full-history redrain, on explicit request -- one HCB request per 100
  # transactions of the org's *entire* history, against a rate limit shared by
  # everyone using this app, which is why the UI warns first.
  #
  # Claimed under a lock, so two people asking at once still only costs one
  # drain. The winner is handed the stream_id that claim is recorded against and
  # streams the walk itself through #page's reload mode, rendering pages as they
  # land instead of watching a cleared screen for minutes. The loser gets no
  # stream and falls back to polling #sync_status for the drain that's already
  # running -- which is the same result, just without the running commentary.
  #
  # A background job is queued behind the stream rather than instead of it: if
  # the tab driving the walk goes away mid-history, WarmOrganizationTransactions
  # Job finishes it from the pages already buffered, so an abandoned reload
  # costs time rather than the whole walk.
  def reload
    transactions = Hcb::OrganizationTransactions.new(hcb_client, organization_id)
    stream_id = SecureRandom.uuid
    claimed = transactions.claim_full_reload!(stream_id)

    if claimed
      # Dropped before the walk starts, not overwritten at the end of it: a
      # reload is a clean slate, and until this runs every other request is
      # still being answered from the drain it's replacing -- including the
      # baseline, which the next ordinary redrain would splice the old rows
      # back on from. See Hcb::OrganizationTransactions#purge!.
      transactions.purge!
      WarmOrganizationTransactionsJob
        .set(wait: WarmOrganizationTransactionsJob::FALLBACK_DELAY)
        .perform_later(current_user.id, organization_id, full: true, stream_id: stream_id)
    end

    render json: {
      status: claimed ? "started" : "already_running",
      stream_id: claimed ? stream_id : nil,
      **transactions.sync_state
    }
  end

  # Progress poll for the background redrain #refresh hands off. Reads local
  # cache only -- never HCB -- so polling it every few seconds can't eat into
  # the org-shared rate limit Hcb::OrganizationTransactions exists to protect.
  def sync_status
    render json: Hcb::OrganizationTransactions.new(hcb_client, organization_id).sync_state
  end

  private

  # Re-derives every active match this transaction is a leg of, now that HCB may
  # have restated it -- or stopped accounting for it, in which case the leg is
  # dropped from the match and what's left is re-derived without it. Reported
  # either way so the frontend can tell the user their match changed (and
  # re-render it into the right bucket). Built after the splice above, so the
  # ledger reads the refreshed value.
  def resync_matches_for(transaction_id)
    match_ids = MatchTransaction.active
      .where(hcb_organization_id: organization_id, hcb_transaction_id: transaction_id)
      .select(:match_id)
    matches = Match.active.for_organization(organization_id)
      .where(id: match_ids).includes(:match_transactions, :adjustments)

    Matches::Resync.new(ledger: OrganizationLedger.new(hcb_client, organization_id), matches: matches).call.match_changes
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
