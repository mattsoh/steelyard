class AddDroppedAtToMatchTransactions < ActiveRecord::Migration[8.1]
  def change
    # A leg HCB has stopped accounting for (Matches::Resync drops it from the
    # match and re-derives what's left). Soft rather than destructive so the
    # same transaction being remapped *back* into the organization can put the
    # leg back -- see Matches::Resync#restore.
    add_column :match_transactions, :dropped_at, :datetime

    # A dropped leg isn't part of its match any more, so it must stop holding
    # the transaction against a new one. Without this, a transaction that came
    # back could never be matched again: the old dropped row would still be
    # occupying its slot in the uniqueness constraint.
    remove_index :match_transactions,
      column: [ :hcb_organization_id, :hcb_transaction_id ],
      name: "index_match_transactions_on_active_txn_per_org"
    add_index :match_transactions,
      [ :hcb_organization_id, :hcb_transaction_id ],
      unique: true,
      where: "(undone_at IS NULL AND dropped_at IS NULL)",
      name: "index_match_transactions_on_active_txn_per_org"
  end
end
