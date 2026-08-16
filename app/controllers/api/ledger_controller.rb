class Api::LedgerController < ApplicationController
  include OrganizationScoped

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
    transactions = Hcb::OrganizationTransactions.new(hcb_client, organization_id).all
    # Sorted by the same date the table displays -- Hcb::TransactionPresenter#date,
    # i.e. when the transaction was *sent*, which is the date this whole app
    # reckons in (the matcher's panels and date filters use it too). HCB's own
    # `date` is the settled one, and sorting by it while showing the sent one
    # left the ledger reading out of order for every ACH/check/wire where the
    # two diverge. Id breaks ties so the order is stable across requests.
    sorted = transactions
      .map { |t| Hcb::TransactionPresenter.new(t) }
      .sort_by { |p| [ p.date.to_s, p.id.to_s ] }
    cutoff = ledger.effective_cutoff

    running = 0.0
    rows = sorted.map do |presenter|
      # A declined transaction carries the amount that was *attempted*, and no
      # money ever moved -- adding it in would skew the balance of every row
      # after it. It stays in the table (this view is the full history,
      # declines included), just not in the running total. Same reasoning as
      # OrganizationLedger#transactions, which rejects them outright.
      running = (running + presenter.amount).round(2) unless presenter.declined?
      presenter.as_json.merge(running_balance: running, is_zero_point: cutoff&.transaction_id == presenter.id)
    end

    render json: {
      zero_balance_date: cutoff&.date,
      zero_balance_selected_id: cutoff&.transaction_id,
      zero_balance_options: ledger.zero_options.map { |o| { date: o.date, transaction_id: o.transaction_id, beginning: o.beginning? } },
      final_balance: rows.last&.fetch(:running_balance) || 0.0,
      ledger: rows
    }
  end

  # One HCB page at a time, so the frontend can render rows as they arrive
  # instead of blocking on the full drain #index needs for running balances.
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
end
