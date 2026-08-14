# An OAuth connection is an api_token like any other -- same digest lookup,
# same revoke button on the tokens page -- with an issuing client, an expiry,
# and a refresh token attached. Keeping them in one table means one
# authentication path and one place to cut a client off.
class AddOauthToApiTokens < ActiveRecord::Migration[8.0]
  def change
    add_column :api_tokens, :oauth_client_id, :bigint
    add_column :api_tokens, :expires_at, :datetime
    add_column :api_tokens, :refresh_token_digest, :string
    add_column :api_tokens, :scope, :string

    add_index :api_tokens, :refresh_token_digest, unique: true
    add_foreign_key :api_tokens, :oauth_clients
  end
end
