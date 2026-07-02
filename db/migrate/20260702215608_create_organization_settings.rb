class CreateOrganizationSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :organization_settings do |t|
      t.string :hcb_organization_id, null: false
      t.string :zero_balance_transaction_id
      t.string :zero_balance_date
      t.bigint :updated_by_user_id, null: false

      t.timestamps
    end
    add_index :organization_settings, :hcb_organization_id, unique: true
    add_foreign_key :organization_settings, :users, column: :updated_by_user_id
  end
end
