class SessionsController < ApplicationController
  skip_before_action :require_login!, only: [ :new, :callback, :destroy, :dev_login ]


  def new
    state = SecureRandom.hex(16)
    session[:oauth_state] = state
    redirect_to Hcb.oauth_client.auth_code.authorize_url(
      redirect_uri: ENV.fetch("HCB_OAUTH_REDIRECT_URI"),
      scope: "restricted organizations:read ledgers:read",
      state: state
    ), allow_other_host: true
  end

  def callback
    if params[:state].blank? || params[:state] != session.delete(:oauth_state)
      redirect_to login_path, alert: "Login failed: invalid OAuth state." and return
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
  rescue OAuth2::Error
    redirect_to login_path, alert: "Login with HCB failed. Please try again."
  end

  def destroy
    reset_session
    redirect_to login_path
  end
end
