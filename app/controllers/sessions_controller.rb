class SessionsController < ApplicationController
  skip_before_action :require_login!, only: [ :new, :callback, :destroy ]


  def new
    state = SecureRandom.hex(16)
    session[:oauth_state] = state
    redirect_to Hcb.oauth_client.auth_code.authorize_url(
      scope: "restricted users:read organizations:read ledgers:read comments:read",
      state: state,
      redirect_uri: ENV.fetch("HCB_OAUTH_REDIRECT_URI")
    ), allow_other_host: true
  end

  def callback
    expected_state = session.delete(:oauth_state)

    if params[:error].present?
      return render_login_error("HCB login failed: #{params[:error_description] || params[:error]}")
    end

    if params[:state].blank? || params[:state] != expected_state
      return render_login_error("Login failed: invalid OAuth state.")
    end

    token = Hcb.oauth_client.auth_code.get_token(
      params[:code], redirect_uri: ENV.fetch("HCB_OAUTH_REDIRECT_URI")
    )


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
    redirect_to return_path_after_login
  rescue OAuth2::Error => e
    render_login_error("Login with HCB failed: #{e.message}")
  end

  def destroy
    current_user&.update(access_token: nil, refresh_token: nil, token_expires_at: nil)
    reset_session
    redirect_to root_path
  end

  private

  # Somewhere this app parked before sending the user off to log in -- today
  # that's the OAuth consent screen, which a client sends people to with a URL
  # full of parameters nobody could retype. Only ever a path this app wrote, and
  # re-checked here anyway: a redirect target that came from outside would make
  # the login flow a way to bounce people somewhere else entirely.
  def return_path_after_login
    parked = session.delete(:return_to).to_s
    parked.start_with?("/") && !parked.start_with?("//") ? parked : organizations_path
  end

  def render_login_error(message)
    render plain: "#{message}\n\nTry logging in again: #{login_url}", status: :unauthorized
  end
end
