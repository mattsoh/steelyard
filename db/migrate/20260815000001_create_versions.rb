# PaperTrail's change log, covering the records this app actually owns:
# matches, their legs and adjustments, and the per-org cutoff setting. It is a
# forensic record only -- nothing reads it to decide application behaviour, and
# the existing undone_at/undone_by_user_id columns remain the source of truth
# for what a match currently *is*.
#
# Two columns beyond PaperTrail's defaults:
#
#   hcb_organization_id  so an org's history can be read straight off this
#                        table. Populated from the record itself (see
#                        Auditable), not from the request, so a version written
#                        by a rake task carries it too.
#   request_id           groups every version written while serving one
#                        request. Moving a cutoff cascade-undoes other people's
#                        matches, and this is what ties those undos back to the
#                        cutoff change that caused them rather than leaving
#                        them looking like six unrelated manual undos.
class CreateVersions < ActiveRecord::Migration[8.0]
  def change
    create_table :versions do |t|
      t.string :item_type, null: false
      t.bigint :item_id, null: false
      t.string :event, null: false
      # A user id, or a "system:*" marker for changes no person asked for
      # (see AuditVersion). Deliberately not a foreign key: a version has to
      # outlive whatever it points at.
      t.string :whodunnit
      t.string :hcb_organization_id
      t.string :request_id

      # jsonb rather than PaperTrail's default serialized text, so the history
      # is queryable in SQL -- `object_changes -> 'discrepancy_cents'` is the
      # whole point of keeping it.
      t.jsonb :object
      t.jsonb :object_changes

      t.datetime :created_at, null: false
    end

    add_index :versions, [ :item_type, :item_id ]
    add_index :versions, [ :hcb_organization_id, :created_at ]
    add_index :versions, :request_id
  end
end
