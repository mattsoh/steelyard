# Records every create/update/destroy of the including model to the versions
# table (see AuditVersion), which is where the answers to "who changed this
# match, and what did it say before?" live -- the records themselves keep only
# their current state plus who created and who undid them.
#
# Only this app's own bookkeeping is audited. HCB's transactions are read-only
# and live in HCB, so nothing here tracks them; what a version can show is the
# *consequence* of one changing, e.g. a discrepancy re-derived by
# Matches::Resync.
module Auditable
  extend ActiveSupport::Concern

  included do
    has_paper_trail versions: { class_name: "AuditVersion" },
                    meta: { hcb_organization_id: ->(record) { record.audited_organization_id } }
  end

  # Stamped onto the version so an org's history is one indexed query rather
  # than a walk through every polymorphic item type. Read from the record, so
  # it's present even when the change came from a rake task with no request
  # around it.
  def audited_organization_id = hcb_organization_id
end
