class CreateOauthClients < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_clients do |t|
      t.string :client_id, null: false
      t.string :name, null: false
      t.jsonb :redirect_uris, null: false, default: []
      # Null for a public client, which is what Claude registers as. Only a
      # client that asked for confidential-client authentication has one.
      t.string :secret_digest
      t.datetime :last_used_at

      t.timestamps
    end
    add_index :oauth_clients, :client_id, unique: true
  end
end
