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
      get("/api/v4/organizations/#{segment(id)}", **(expand.any? ? { expand: expand } : {}))
    end

    def transactions(organization_id, after: nil, limit: 100, filters: {})
      get(
        "/api/v4/organizations/#{segment(organization_id)}/transactions",
        after: after,
        limit: limit,
        filters: filters
      )
    end

    def transaction(id) = get("/api/v4/transactions/#{segment(id)}")

    # HCB serves comments off a shallow, query-parameterized route rather than
    # nesting them under the transaction: /api/v4/transactions/:id/comments
    # doesn't exist and falls through to the v4 catch-all as a 404. (There is a
    # nested form, but only under an organization, and it's deprecated.)
    def comments(transaction_id) = get("/api/v4/comments", transaction_id: transaction_id)

    # Refreshes the token now, on the calling thread, so a caller about to fan
    # out concurrent requests (OrganizationTransactions#parallel_pages) does the
    # refresh once here rather than having every worker thread race into
    # #ensure_fresh_token! -- which takes a row lock and would serialize the
    # fan-out on the database instead of on HCB.
    def warm_token! = ensure_fresh_token!

    private

    # An id or slug going into a URL *path*, escaped.
    #
    # Query values are escaped for us on the way out; path segments are plain
    # string interpolation, and the ids reaching these methods include route
    # parameters straight off the wire. Rails' router unescapes a segment after
    # matching it, so `/api/v1/organizations/a%2F..%2F..%2Fadmin/transactions`
    # arrives as `params[:organization_id] == "a/../../admin"` -- interpolated
    # raw, and normalized by the HTTP client, that addresses an HCB endpoint
    # other than the one this method names. Nothing worse than the caller's own
    # token can reach today (every request here is a GET made with the signed-in
    # user's own HCB credentials, so it can only read what they could read from
    # HCB directly), which is the only reason this isn't urgent -- but "the
    # caller picks the endpoint" is not a property to leave lying around for the
    # first method here that writes something.
    def segment(value) = ERB::Util.url_encode(value.to_s)

    def get(path, **params)
      response = access_token.get(path, params: params.compact)
      JSON.parse(response.body)
    rescue OAuth2::Error => e
      # 401 is an expired/revoked token; 403 from HCB's "restricted" tokens
      # means the token predates a scope this app now requires (e.g.
      # comments:read, added after some users had already authorized) --
      # both are only fixable by sending the user through the OAuth flow
      # again to pick up the current scope list.
      raise Hcb::TokenExpiredError, e.message if e.response.status.in?([ 401, 403 ])
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
