# The one-page-at-a-time endpoint the matcher and the ledger both stream from.
# Same rows either way (Hcb::TransactionPresenter's shape) -- they just lay them
# out differently -- so the paging, the full-reload mode, and the background
# handover below live here rather than twice.
module StreamedTransactionPages
  extend ActiveSupport::Concern

  private

  def streamed_page_json
    transactions = Hcb::OrganizationTransactions.new(hcb_client, organization_id)
    stream_id = params[:stream_id].to_s
    reload = params[:reload].present?
    first_page = params[:after].blank?

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

    # A cold first drain has just been claimed by this browser, so something has
    # to stand behind it. Queued on the first page only, and only when the walk
    # is actually going to take more than one -- a one-page organization is
    # finished and released by the time this line is reached.
    #
    # This is what makes closing the tab cost the walk some time rather than all
    # of it: the job waits for the stream's heartbeat to lapse (or for the
    # handoff beacon to say it's gone), then finishes from the pages already
    # buffered. Reload mode queues its own equivalent in #reload, before the
    # purge, so it isn't duplicated here.
    if !reload && first_page && result[:has_more]
      WarmOrganizationTransactionsJob
        .set(wait: WarmOrganizationTransactionsJob::FALLBACK_DELAY)
        .perform_later(current_user.id, organization_id, full: true, stream_id: stream_id)
    end

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
      reloading: result[:reloading].present?,
      # Answered entirely from cache -- every row, no HCB request. The client
      # stops streaming here and goes straight to the authoritative view rather
      # than asking for a second page it already knows is empty.
      warm: result[:warm].present?,
      # Recent activity was spliced onto the previous drain inside this one
      # request, so this single page IS the whole history. Same short-circuit as
      # `warm`, different reason, and worth distinguishing in the activity log.
      spliced: result[:spliced].present?,
      # Somebody else's walk owns this organization. Not an error and not an
      # empty organization: the caller waits for their result instead of buying
      # a second copy of it out of the shared rate limit.
      waiting: result[:waiting].present?,
      # So a stream that is handing over (or one that just took over) can tell
      # the client how far the *walk* has got, not just this page.
      streamed: result[:streamed],
      stream_id: stream_id.presence,
      # Only on the page that finishes the walk, which is the only point at
      # which a token exists to name the result. It is what the browser keys
      # its own copy of these rows against, so the next load can prove the copy
      # is current with one small request instead of re-reading the
      # organization. Costs a cache read on the last page of a walk, not on
      # every page of it.
      token: (transactions.drain_token unless result[:has_more])
    }
  end

  def render_streamed_page
    json = streamed_page_json
    return render json: { error: "Another full reload is already running." }, status: :conflict if json == :conflict

    render json: json
  end
end
