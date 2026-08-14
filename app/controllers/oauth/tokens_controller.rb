module Oauth
  # Exchanges an authorization code for a token, and later a refresh token for
  # a fresh pair. Form-encoded, per RFC 6749 -- Claude sends both requests that
  # way, and Rails parses them into params without anything special.
  class TokensController < PublicController
    rate_limit to: 60, within: 1.minute,
      with: -> { render_oauth_error("invalid_request", "Too many token requests; try again shortly.", status: :too_many_requests) }

    def create
      case params[:grant_type]
      when "authorization_code" then exchange_code
      when "refresh_token" then refresh
      else render_oauth_error("unsupported_grant_type", "Supported grant types are authorization_code and refresh_token.")
      end
    end

    private

    def exchange_code
      code = OauthAuthorizationCode.find_by_plaintext(params[:code])
      return invalid_grant("That authorization code isn't one we issued.") unless code

      # A code presented twice means it was captured somewhere, so OAuth 2.1
      # has the server assume the worst: kill what the first exchange bought
      # rather than let the two live side by side.
      if code.consumed?
        code.api_token&.revoke!
        return invalid_grant("That authorization code has already been used; the token it issued has been revoked.")
      end

      return invalid_grant("That authorization code has expired.") unless code.usable?

      client = code.oauth_client
      return unless authenticated_client?(client)
      return invalid_grant("That code was issued to a different client.") unless client.client_id == params[:client_id].to_s
      # Pinned at issue time: the code is only good for the exact destination
      # the user saw on the consent screen.
      return invalid_grant("redirect_uri does not match the one the code was issued for.") unless params[:redirect_uri].to_s == code.redirect_uri
      return invalid_grant("code_verifier does not match the code_challenge from the authorization request.") unless code.verifier_matches?(params[:code_verifier])

      token = ApiToken.mint_for_client!(user: code.user, oauth_client: client, scope: code.scope)
      code.update!(consumed_at: Time.current, api_token: token)
      client.update_column(:last_used_at, Time.current)

      render_token(token)
    end

    def refresh
      token = ApiToken.find_by_refresh_token(params[:refresh_token])
      return invalid_grant("That refresh token isn't valid; start the connection again.") unless token&.oauth?
      return unless authenticated_client?(token.oauth_client)
      return invalid_grant("That refresh token was issued to a different client.") unless token.oauth_client.client_id == params[:client_id].to_s

      # Rotated, not reused: the refresh token that bought this response is
      # dead by the time the response is written, which is what OAuth 2.1 asks
      # of a public client.
      render_token(token.refresh!)
    end

    # A public client has no secret to check -- PKCE and the registered
    # redirect URI are what stand in for one. A confidential client has to
    # prove itself, by post body or HTTP Basic.
    def authenticated_client?(client)
      return true if client.authenticates_with?(submitted_client_secret)

      render_oauth_error("invalid_client", "Client authentication failed.", status: :unauthorized)
      false
    end

    def submitted_client_secret
      return params[:client_secret] if params[:client_secret].present?

      credentials = ActionController::HttpAuthentication::Basic.decode_credentials(request).split(":", 2)
      credentials.last if credentials.size == 2
    end

    def render_token(token)
      response.set_header("Cache-Control", "no-store")
      render json: {
        access_token: token.plaintext,
        token_type: "Bearer",
        expires_in: token.expires_in,
        refresh_token: token.plaintext_refresh_token,
        scope: token.scope
      }
    end

    # RFC 6749 is specific that this is the code for a bad code or refresh
    # token, and Claude keys its "reconnect this connector" behaviour off it --
    # a custom or approximate code reads to it as a broken server instead.
    def invalid_grant(description) = render_oauth_error("invalid_grant", description)
  end
end
