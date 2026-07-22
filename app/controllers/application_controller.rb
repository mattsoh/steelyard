class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :require_login!

  rescue_from Hcb::TokenExpiredError do
    reset_session
    # A `fetch()` call (comments, matches, ledger data, etc.) follows a
    # redirect transparently and silently receives the login page's HTML as
    # a 200 -- the caller's `res.ok` is true and `res.json()` just throws,
    # surfacing as a generic "could not load" rather than a re-login prompt.
    # Keying off the controller namespace (rather than the request's Accept
    # header, which the frontend's plain `fetch()` calls don't set) so every
    # Api::* endpoint reliably gets a real 401 the caller can detect, while
    # actual page controllers still get the redirect.
    if controller_path.start_with?("api/")
      render json: { error: "reauth_required" }, status: :unauthorized
    else
      redirect_to root_path, alert: "Your session with HCB expired. Please log in again."
    end
  end

  rescue_from StandardError, with: :report_unexpected_error

  private

  def report_unexpected_error(exception)
    raise exception if Rails.env.local?

    error_id = SecureRandom.hex(4).upcase

    Appsignal.set_error(exception)
    Appsignal.add_tags(error_id: error_id)
    Rails.logger.error("[#{error_id}] #{exception.class}: #{exception.message}")

    respond_to do |format|
      format.json { render json: { error: "Something went wrong.", error_id: error_id }, status: :internal_server_error }
      format.any  { render "errors/internal_server_error", status: :internal_server_error, locals: { error_id: error_id } }
    end
  end

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end
  helper_method :current_user

  def require_login!
    redirect_to root_path unless current_user
  end

  def hcb_client
    @hcb_client ||= Hcb::Client.new(current_user)
  end
end
