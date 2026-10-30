# Runs one organization's load task in the background -- see
# Hcb::OrganizationTransactions#run_task! for what a task is and does.
#
# Every walk of HCB goes through here rather than through whichever browser
# asked for it. A browser that opens a cold organization claims a task
# (Hcb::OrganizationTransactions#ensure_loaded!) and queues this with its id;
# the tab then polls the task's progress like any other viewer, and closing it
# changes nothing about the walk. Before, the tab itself drove the walk a page
# at a time, with this job standing behind it in case the tab went away -- so
# the walk only progressed while that one tab was open, and a tab that joined
# later could only watch a progress bar.
#
# Without a `task_id` this is the periodic background refresh
# (Hcb::OrganizationTransactions#maybe_refresh_ahead): it claims a task of its
# own, and does nothing if another task already owns the organization.
class WarmOrganizationTransactionsJob < ApplicationJob
  queue_as :default

  def perform(user_id, organization_id, filters: {}, task_id: nil)
    user = User.find_by(id: user_id)
    return unless user

    transactions = Hcb::OrganizationTransactions.new(Hcb::Client.for_user(user), organization_id, filters: filters)

    if task_id.nil?
      task_id = transactions.start_task!(kind: transactions.natural_kind, requested_by: "the background refresh")
      return if task_id.nil?
    end

    transactions.run_task!(task_id)
  rescue Hcb::TokenExpiredError
    # Already recorded against the task as a failure by #run_task!, and the
    # claim released. The next request from someone whose token works starts a
    # fresh task with theirs.
    nil
  end
end
