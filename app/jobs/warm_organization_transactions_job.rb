# Re-drains an organization's HCB transactions in the background and writes
# the result to the same cache Hcb::OrganizationTransactions#all reads from,
# so the request that triggered this (see
# Hcb::OrganizationTransactions#maybe_refresh_ahead) doesn't have to wait on
# it -- and neither does the next viewer, once the old cache entry expires.
#
# `full: true` is the user-requested full reload (Api::TransactionsController
# #reload): the same write, but from a complete re-walk of the org's history
# rather than an incremental drain. It runs here for the same reason but more
# so -- on a large org that walk is far longer than a request can wait on.
class WarmOrganizationTransactionsJob < ApplicationJob
  queue_as :default

  def perform(user_id, organization_id, filters: {}, full: false)
    user = User.find_by(id: user_id)
    return unless user

    transactions = Hcb::OrganizationTransactions.new(Hcb::Client.for_user(user), organization_id, filters: filters)
    full ? transactions.reload! : transactions.refresh!
  rescue Hcb::TokenExpiredError
    # Nothing to do -- the next real request from a signed-in user will
    # re-drain and repopulate the cache normally.
  ensure
    # Released even when the drain failed: leaving the claim held would block
    # the retry someone is about to ask for, for the whole lock TTL.
    transactions&.release_full_reload! if full
  end
end
