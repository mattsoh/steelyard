# The one-page-at-a-time endpoint the matcher and the ledger both stream from.
# Same rows either way (Hcb::TransactionPresenter's shape) -- they just lay them
# out differently -- so the paging, and the full-reload mode below, live here
# rather than twice.
module StreamedTransactionPages
  extend ActiveSupport::Concern

  private

  def streamed_page_json
    transactions = Hcb::OrganizationTransactions.new(hcb_client, organization_id)
    stream_id = params[:stream_id].to_s
    reload = params[:reload].present?

    # Reload mode re-walks the organization's entire history from HCB, which is
    # why it's claimed (Api::TransactionsController#reload) before it's streamed
    # and only honoured for the stream holding that claim. Without this check
    # it'd be a full-history drain any caller could ask for at will, against a
    # rate limit the whole organization shares -- and two tabs could each start
    # one. A caller that lost the claim gets :conflict rather than the ordinary
    # cached page, so it can tell "someone else is reloading, wait for theirs"
    # from "here is the data you asked to re-read".
    return :conflict if reload && !transactions.full_reload_stream?(stream_id)

    result = transactions.fetch_page(stream_id: stream_id, after: params[:after].presence, reload: reload)

    {
      rows: result[:data].map { |t| Hcb::TransactionPresenter.new(t).as_json },
      has_more: result[:has_more],
      next_after: result[:next_after],
      total_count: result[:total_count],
      # What this page actually cost, and how much of it was HCB. The page's
      # activity log reads this to say whether a slow load is us or them, which
      # is otherwise pure guesswork from the outside -- a warm page is a couple
      # of cache reads, a cold one is a round trip to HCB per hundred rows.
      hcb: hcb_client.stats,
      # Passed through, not dropped: an empty page during a full reload means
      # "wait for the drain that's rebuilding this" rather than "there are no
      # transactions", and the client can only tell the two apart from this.
      reloading: result[:reloading].present?
    }
  end

  def render_streamed_page
    json = streamed_page_json
    return render json: { error: "Another full reload is already running." }, status: :conflict if json == :conflict

    render json: json
  end
end
