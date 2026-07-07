module Hcb
  # Thin wrapper around the HCB v4 API, scoped to one logged-in user's token.
  # Refreshes the OAuth token proactively before use (rather than reactively on
  # a 401) since a 401-then-retry would spend a second request against the
  # rate limit that this app's whole userbase shares against one HCB app.
  class Client
    def self.for_user(user) = new(user)

    def initialize(user)
      @user = user
    end

    def user_id = @user.id

    def user = get("/api/v4/user")
    def organizations = get("/api/v4/user/organizations")

    def organization(id, expand: [])
      get("/api/v4/organizations/#{id}", **(expand.any? ? { expand: expand } : {}))
    end

    def transactions(organization_id, after: nil, limit: 100, filters: {})
      get(
        "/api/v4/organizations/#{organization_id}/transactions",
        after: after,
        limit: limit,
        filters: filters
      )
    end

    def transaction(id) = get("/api/v4/transactions/#{id}")

    private

    def get(path, **params)
      response = access_token.get(path, params: params.compact)
      JSON.parse(response.body)
    rescue OAuth2::Error => e
      raise Hcb::TokenExpiredError, e.message if e.response.status == 401
      raise
    end

    def access_token
      ensure_fresh_token!
      OAuth2::AccessToken.new(
        Hcb.oauth_client,
        @user.access_token,
        refresh_token: @user.refresh_token,
        expires_at: @user.token_expires_at.to_i
      )
    end

    def ensure_fresh_token!
      return if @user.token_fresh?

      @user.with_lock do
        @user.reload
        next if @user.token_fresh?

        stale = OAuth2::AccessToken.new(
          Hcb.oauth_client, @user.access_token,
          refresh_token: @user.refresh_token, expires_at: @user.token_expires_at.to_i
        )
        fresh = stale.refresh
        @user.update!(
          access_token: fresh.token,
          refresh_token: fresh.refresh_token || @user.refresh_token,
          token_expires_at: Time.at(fresh.expires_at)
        )
      end
    rescue OAuth2::Error
      raise Hcb::TokenExpiredError, "refresh token invalid or revoked"
    end
  end
end
