# Re-drains an organization's HCB transactions in the background and writes
# the result to the same cache Hcb::OrganizationTransactions#all reads from,
# so the request that triggered this (see
# Hcb::OrganizationTransactions#maybe_refresh_ahead) doesn't have to wait on
# it -- and neither does the next viewer, once the old cache entry expires.
#
# `stream_id` is the fallback behind a browser-driven full reload
# (Api::TransactionsController#reload): the tab that asked for it streams the
# pages itself so it can render them as they arrive, and this stands behind
# that in case the tab goes away mid-walk. It waits for the stream's heartbeat
# to go quiet, then finishes the drain from the pages already buffered -- so
# closing the tab costs the reload some time, not the whole walk.
#
# `full: true` with no stream is the same reload paid for entirely in the
# background: what a caller that can't stream (or lost the claim to another
# tab) falls back to.
class WarmOrganizationTransactionsJob < ApplicationJob
  queue_as :default

  # How long to leave a streaming reload alone before checking whether it's
  # still going. Comfortably longer than FULL_RELOAD_HEARTBEAT_TIMEOUT, so the
  # first check is a decision rather than a near-certain reschedule.
  FALLBACK_DELAY = 2.minutes

  # Bounds the reschedule loop below. At FALLBACK_DELAY apiece this outlasts
  # FULL_RELOAD_LOCK_TTL, so a stream that keeps its claim alive for longer
  # than a reload can plausibly take runs out of watchers rather than leaving a
  # job rescheduling itself forever.
  MAX_FALLBACK_CHECKS = 10

  def perform(user_id, organization_id, filters: {}, full: false, stream_id: nil, check: 1)
    user = User.find_by(id: user_id)
    return unless user

    transactions = Hcb::OrganizationTransactions.new(Hcb::Client.for_user(user), organization_id, filters: filters)

    if stream_id.present?
      stand_by_for_stream(transactions, user_id, organization_id, stream_id, check)
    elsif full
      # Released whatever happens: a claim left behind by a drain that died
      # would block the retry someone is about to ask for for its whole TTL.
      begin
        transactions.reload!
      ensure
        transactions.release_full_reload!
      end
    else
      transactions.refresh!
    end
  rescue Hcb::TokenExpiredError
    # Nothing to do -- the next real request from a signed-in user will
    # re-drain and repopulate the cache normally.
    nil
  end

  private

  # Takes the reload over only once the stream driving it has actually stopped;
  # while it's still fetching pages, this checks back rather than draining
  # alongside it, which would spend the shared rate limit twice over on the
  # same history.
  def stand_by_for_stream(transactions, user_id, organization_id, stream_id, check)
    outcome =
      begin
        transactions.resume_full_reload!(stream_id)
      rescue StandardError
        # Same reasoning as the inline path above -- except that a *live* stream
        # is the one case where the claim isn't ours to drop, and reaching here
        # means we tried to take it over, so it is.
        transactions.release_full_reload!
        raise
      end

    return unless outcome == :running
    return if check >= MAX_FALLBACK_CHECKS

    self.class.set(wait: FALLBACK_DELAY)
      .perform_later(user_id, organization_id, full: true, stream_id: stream_id, check: check + 1)
  end
end
