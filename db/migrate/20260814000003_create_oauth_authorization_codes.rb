class CreateOauthAuthorizationCodes < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_authorization_codes do |t|
      t.string :code_digest, null: false
      t.bigint :oauth_client_id, null: false
      t.bigint :user_id, null: false
      t.string :redirect_uri, null: false
      t.string :code_challenge, null: false
      t.string :scope, null: false
      # The MCP server URL the client said it wanted a token for (RFC 8707).
      t.string :resource
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      # The token this code was exchanged for, so a replayed code can revoke
      # what it already bought -- see Oauth::TokensController.
      t.bigint :api_token_id

      t.timestamps
    end
    add_index :oauth_authorization_codes, :code_digest, unique: true
    add_index :oauth_authorization_codes, :expires_at
    add_foreign_key :oauth_authorization_codes, :oauth_clients
    add_foreign_key :oauth_authorization_codes, :users
  end
end
