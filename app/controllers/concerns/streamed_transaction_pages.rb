# The endpoint the matcher and the ledger both load their rows through. Same
# rows either way (Hcb::TransactionPresenter's shape) -- they just lay them out
# differently -- so this lives here rather than twice.
#
# It answers one of two ways. Warm: the whole drained history in one response,
# pre-serialized from the drain's presentation cache. Cold: the task that is
# building it (started here if nothing is), with the pages that task has
# fetched so far and the activity it has logged. The caller renders those
# pages, then polls with `after_page` set to how many it has, until a response
# comes back warm.
#
# Nothing here depends on which browser asked. The task runs in a job, every
# viewer polls the same record, and a tab that joins half-way gets every page
# the task has already fetched in its first response.
module StreamedTransactionPages
  extend ActiveSupport::Concern

  private

  def render_streamed_page
    transactions = Hcb::OrganizationTransactions.new(hcb_client, organization_id)
    log_after = params[:log_after].presence

    cached = transactions.full_reload_running? ? nil : transactions.cached_all
    if cached
      render json: warm_page_json(transactions, cached, log_after: log_after)
      return
    end

    task = transactions.ensure_loaded!(
      requested_by: requester_name,
      user_id: current_user.id,
      # The explicit retry after a failed load -- without it, a recent failure
      # is left alone rather than restarted by every poll (see
      # Hcb::OrganizationTransactions::FAILURE_BACKOFF).
      force: params[:retry].present?
    )

    # The task landed between the check above and this one. Its result is
    # warm now, so answer with that rather than an empty page the caller would
    # have to come back for.
    cached = transactions.cached_all unless task && task[:running]
    if cached
      render json: warm_page_json(transactions, cached, log_after: log_after)
      return
    end

    after_page = params[:after_page].to_i
    rows = transactions.task_pages(after_page).map { |t| Hcb::TransactionPresenter.new(t).as_json }

    render json: {
      warm: false,
      rows: rows,
      # How many pages the rows above bring the caller up to -- what it passes
      # back as `after_page` next time.
      pages_done: task && task[:kind].in?(Hcb::DrainProgress::BUFFERED_KINDS) ? task[:pages_done].to_i : 0,
      total_count: task && task[:total_count],
      progress: task,
      log: transactions.activity.read(after: log_after),
      hcb: hcb_client.stats
    }
  end

  # Assembled as a string rather than a Hash handed to #to_json, for the same
  # reason Api::TransactionsController#index is: the rows come out of the
  # presentation cache already serialized, and re-parsing them to re-generate
  # identical bytes is the single most expensive thing this endpoint could do.
  # The fallback presents inline for a drain whose presentation cache hasn't
  # landed yet (an older cache entry, a side cache that expired first).
  def warm_page_json(transactions, cached, log_after:)
    presented = transactions.presented
    fragments =
      if presented && cached.all? { |t| presented.key?(t["id"]) }
        cached.map { |t| presented[t["id"]] }
      else
        cached.map { |t| Hcb::TransactionPresenter.new(t).as_json.to_json }
      end

    json_object(
      warm: true.to_json,
      rows: "[#{fragments.join(',')}]",
      pages_done: 0.to_json,
      total_count: cached.size.to_json,
      # What the browser keys its own copy of these rows against, so the next
      # load can prove the copy is current with one small request instead of
      # re-reading the organization.
      token: transactions.drain_token.to_json,
      progress: transactions.progress.read.to_json,
      log: transactions.activity.read(after: log_after).to_json,
      hcb: hcb_client.stats.to_json
    )
  end

  # Who to record as having asked for a load, in the activity log everyone
  # sees. The name HCB gave us, or the email where there isn't one.
  def requester_name
    current_user.name.presence || current_user.email.presence || "someone"
  end
end
