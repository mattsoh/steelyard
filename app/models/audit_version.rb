# A row in the change log PaperTrail writes for every model that includes
# Auditable. Its own class rather than PaperTrail::Version so `whodunnit` --
# which holds a bare string -- can be read back as the person (or the process)
# responsible without every caller reimplementing that.
class AuditVersion < ApplicationRecord
  include PaperTrail::VersionConcern

  self.table_name = "versions"

  # Changes nobody asked for: written by background re-derivation rather than
  # by a user action, so `whodunnit` names the process instead of a user id.
  # Prefixed so it can never collide with one -- ids are digits only.
  SYSTEM_PREFIX = "system:".freeze

  # Every version written while serving one request, cutoff moves included --
  # see the migration for why that matters.
  scope :for_request, ->(request_id) { where(request_id: request_id) }
  scope :for_organization, ->(org_id) { where(hcb_organization_id: org_id) }

  def system? = whodunnit.to_s.start_with?(SYSTEM_PREFIX)

  # nil for a system change, and also for a user since deleted -- callers get
  # the same "no person to point at" either way.
  def user
    return nil if system? || whodunnit.blank?

    @user ||= User.find_by(id: whodunnit)
  end

  # Whatever there is to display: a person's name, else the process that acted,
  # else an honest admission that the record no longer says.
  def actor_name
    return whodunnit.delete_prefix(SYSTEM_PREFIX) if system?

    user&.name.presence || user&.email.presence || "unknown"
  end
end
