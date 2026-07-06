class SessionsController < ApplicationController
  skip_before_action :require_login!, only: [ :new, :callback, :destroy ]


  def new 
    state = SecureRandom.hex(16)
    session[:oauth_state] = state
    redirect_to Hcb.oauth_client.auth_code.authorize_url(
      redirect_uri: ENV.fetch("HCB_OAUTH_REDIRECT_URI"),
      # "restricted" turns on per-action OAuth scope enforcement on HCB's
      # side; without it a token gets full legacy access regardless of the
      # other scopes listed. users:read covers GET /api/v4/user (users#me)
      # and organizations:read covers GET /api/v4/user/organizations
      # (events#index), in addition to guarding the organization/transaction
      # endpoints below.
      scope: "restricted users:read organizations:read ledgers:read",
      state: state
    ), allow_other_host: true
  end

  def callback
    expected_state = session.delete(:oauth_state)

    # Rendered directly rather than redirected to login_path: that path immediately
    # bounces back to HCB, so redirecting a failure there is an infinite loop with no
    # chance for the user (or us) to see what went wrong.
    if params[:error].present?
      return render_login_error("HCB login failed: #{params[:error_description] || params[:error]}")
    end

    if params[:state].blank? || params[:state] != expected_state
      return render_login_error("Login failed: invalid OAuth state.")
    end

    token = Hcb.oauth_client.auth_code.get_token(
      params[:code], redirect_uri: ENV.fetch("HCB_OAUTH_REDIRECT_URI")
    )
    # Fetched directly off the fresh token rather than through Hcb::Client,
    # since that wrapper's refresh logic needs an already-persisted User.
    identity = JSON.parse(token.get("/api/v4/user").body)

    user = User.find_or_initialize_by(hcb_user_id: identity["id"])
    user.update!(
      access_token: token.token,
      refresh_token: token.refresh_token,
      token_expires_at: Time.at(token.expires_at),
      email: identity["email"],
      name: identity["name"]
    )

    session[:user_id] = user.id
    redirect_to organizations_path
  rescue OAuth2::Error => e
    render_login_error("Login with HCB failed: #{e.message}")
  end

  def destroy
    reset_session
    redirect_to login_path
  end

  private

  def render_login_error(message)
    render plain: "#{message}\n\nTry logging in again: #{login_url}", status: :unauthorized
  end
end
