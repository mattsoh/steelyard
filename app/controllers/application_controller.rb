class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :require_login!
  before_action :set_paper_trail_whodunnit

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

  # Who to credit for anything Auditable writes during this request.
  #
  # Deliberately a lambda: PaperTrail evaluates a callable whodunnit at the
  # moment the version row is built, not when it's assigned. That's what lets
  # this be a plain before_action even on the token-authenticated surfaces
  # (/api/v1, MCP), where `current_user` isn't resolved until
  # TokenAuthenticated's `authenticate_token!` -- declared in the including
  # class, so it runs *after* this inherited callback. Reading current_user
  # here and now would credit every MCP-driven change to nobody.
  def user_for_paper_trail = -> { current_user&.id&.to_s }

  # Stamped on every version written while serving this request, which is how
  # the matches a cutoff move cascade-undoes stay tied to the cutoff change
  # that caused them (see Cutoffs::Update).
  def info_for_paper_trail = { request_id: request.request_id }
end
