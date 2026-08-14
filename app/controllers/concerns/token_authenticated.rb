# Bearer-token authentication for the surfaces that programs talk to (the v1
# REST API and the MCP endpoint), in place of the session cookie the browser
# uses. A token stands in for exactly one user, and everything it can reach is
# still bounded by that user's HCB membership and role -- it grants no access
# its owner doesn't already have through the web app.
module TokenAuthenticated
  extend ActiveSupport::Concern

  included do
    # The session is the browser's credential, and CSRF protection exists to
    # stop a browser being tricked into spending one. Neither applies to a
    # caller that has to present a token it was deliberately given.
    skip_before_action :require_login!
    skip_forgery_protection

    before_action :authenticate_token!
    # These surfaces speak JSON and nothing else, including when
    # ApplicationController's unexpected-error handler is the one answering --
    # without this a client sending `Accept: */*` gets an HTML error page.
    before_action { request.format = :json }

    # ApplicationController's handler resets the session and redirects a browser
    # to the login page, neither of which means anything here. What a token
    # client needs to hear is that its *owner* has to reauthorize with HCB,
    # which only they can do. Declared in the including class so it takes
    # precedence over the inherited handler.
    rescue_from Hcb::TokenExpiredError do
      render_token_error("This token's owner needs to sign in to Steelyard again — their HCB authorization has expired.", :unauthorized)
    end
  end

  # Overrides ApplicationController's session lookup. Defined in the module so
  # it sits ahead of ApplicationController in the ancestry of any controller
  # that includes this.
  def current_user = @current_user

  private

  def authenticate_token!
    @api_token = ApiToken.authenticate(bearer_token)
    unless @api_token
      return render_token_error("Send a Steelyard API token as `Authorization: Bearer <token>`.", :unauthorized)
    end

    @current_user = @api_token.user
    @api_token.touch_last_used!
  end

  def bearer_token = request.authorization.to_s[/\ABearer[ \t]+(.+)\z/i, 1]

  # Both including surfaces answer errors in their own shape (plain JSON for
  # REST, a JSON-RPC envelope for MCP), so each provides its own.
  def render_token_error(message, status)
    raise NotImplementedError, "#{self.class} must define #render_token_error"
  end
end
