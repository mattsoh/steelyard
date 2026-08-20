class Api::LedgerController < ApplicationController
  include OrganizationScoped
  include RawJsonRendering
  include StreamedTransactionPages

  # running_balance here is cumulative only within the cached window, not the
  # true HCB account balance (that would need full account history, which
  # would blow the shared rate limit) -- a deliberate, flagged deviation from
  # the old CSV-derived ledger, which had the same caveat (labeled "(CSV)").
  #
  # The cutoff shown/settable here is the same organization-wide setting the
  # matcher uses (see Api::TransactionsController, OrganizationLedger) --
  # changing it from either page has the same effect, including cascading to
  # undo matches that would span it. Unlike the matcher, this view doesn't
  # filter transactions down to after_cutoff -- it shows the full history
  # (declined transactions included, which the matcher's ledger excludes) and
  # just flags which row the cutoff falls on, matched by id rather than the
  # matcher's index since the two lists aren't in the same order or filtered
  # the same way.
  #
  # Those two orders differ in a way worth knowing about: the cutoff's
  # zero-balance crossings are derived in HCB's drain order (by settled date --
  # see OrganizationTransactions#write_side_caches), while the rows and running
  # balance below are ordered by sent date. Where a transaction settles on a
  # different day than it was sent, the row flagged as the zero point can
  # therefore carry a running balance that isn't exactly $0.
  def index
    ledger = OrganizationLedger.new(hcb_client, organization_id)
    transactions = Hcb::OrganizationTransactions.new(hcb_client, organization_id)
    # Ahead of the rows, because resolving the cutoff is what guarantees a
    # drain has happened at all -- and therefore that the presentation caches
    # the rows are assembled from have been written.
    cutoff = ledger.effective_cutoff
    rows, final_balance_cents = rows_for(transactions, cutoff)

    render json: json_object(
      zero_balance_date: cutoff&.date.to_json,
      zero_balance_selected_id: cutoff&.transaction_id.to_json,
      zero_balance_options: ledger.zero_options.map { |o| { date: o.date, transaction_id: o.transaction_id, beginning: o.beginning? } }.to_json,
      final_balance: (final_balance_cents / 100.0).round(2).to_json,
      ledger: "[#{rows.join(',')}]"
    )
  end

  # One HCB page at a time, so the frontend can render rows as they arrive
  # instead of blocking on the full drain #index needs for running balances.
  def page
    render_streamed_page
  end

  private

  # The table's rows, each already serialized, plus the balance they end on.
  #
  # Ordered by the same date the table displays -- Hcb::TransactionPresenter
  # #date, i.e. when the transaction was *sent*, which is the date this whole
  # app reckons in (the matcher's panels and date filters use it too). HCB's
  # own `date` is the settled one, and sorting by it while showing the sent one
  # left the ledger reading out of order for every ACH/check/wire where the two
  # diverge. Id breaks ties so the order is stable across requests.
  #
  # That ordering, and the rendered row it points at, are both computed once
  # per drain (Hcb::OrganizationTransactions#ledger_order and #presented) --
  # this reads them. The inline fallback below is for the window where they
  # haven't been written yet: a cache entry from before they existed, or a
  # drain whose side caches have expired out from under the primary one.
  def rows_for(transactions, cutoff)
    order = transactions.ledger_order
    presented = order && transactions.presented
    # Two separate cache entries, so a drain landing between the two reads can
    # hand back an order and a set of rows that don't describe the same
    # history. Cheap to notice (hash lookups over ids already in memory), and
    # the answer is the same fallback as a cold cache.
    presented = nil unless presented && order[:ids].all? { |id| presented.key?(id) }

    unless presented
      sorted = transactions.all
        .map { |t| Hcb::TransactionPresenter.new(t) }
        .sort_by { |p| [ p.date.to_s, p.id.to_s ] }
      presented = sorted.to_h { |p| [ p.id, p.as_json.to_json ] }
      order = { ids: sorted.map(&:id), amounts_cents: sorted.map(&:amount_cents), declined: sorted.map(&:declined?) }
    end

    running_cents = 0
    rows = order[:ids].each_with_index.map do |id, i|
      # A declined transaction carries the amount that was *attempted*, and no
      # money ever moved -- adding it in would skew the balance of every row
      # after it. It stays in the table (this view is the full history,
      # declines included), just not in the running total. Same reasoning as
      # OrganizationLedger#transactions, which rejects them outright.
      running_cents += order[:amounts_cents][i] unless order[:declined][i]
      json_object_with(presented[id],
        running_balance: (running_cents / 100.0).round(2),
        is_zero_point: cutoff&.transaction_id == id)
    end

    [ rows, running_cents ]
  end
end
