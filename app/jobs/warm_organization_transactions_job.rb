# Re-drains an organization's HCB transactions in the background and writes
# the result to the same cache Hcb::OrganizationTransactions#all reads from,
# so the request that triggered this (see
# Hcb::OrganizationTransactions#maybe_refresh_ahead) doesn't have to wait on
# it -- and neither does the next viewer, once the old cache entry expires.
class WarmOrganizationTransactionsJob < ApplicationJob
  queue_as :default

  def perform(user_id, organization_id, filters: {})
    user = User.find_by(id: user_id)
    return unless user

    Hcb::OrganizationTransactions
      .new(Hcb::Client.for_user(user), organization_id, filters: filters)
      .refresh!
  rescue Hcb::TokenExpiredError
    # Nothing to do -- the next real request from a signed-in user will
    # re-drain and repopulate the cache normally.
  end
end
