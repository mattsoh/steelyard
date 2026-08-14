module Oauth
  # The consent screen: the one point in the flow where a person, signed in to
  # Steelyard with their own HCB account, decides whether a client may act as
  # them. Everything the resulting token can do follows from that decision --
  # the token carries their HCB membership and role, and matches it makes are
  # recorded under their name.
  #
  # Unlike the endpoints in PublicController, this one needs a session: it
  # inherits ApplicationController's require_login!, and #new parks the request
  # so the user lands back here after logging in with HCB.
  class AuthorizationsController < ApplicationController
    # Prepended, not appended: ApplicationController's require_login! is
    # declared first and halts the chain when it redirects, so a callback added
    # after it never runs for the signed-out visitor this one exists for.
    prepend_before_action :remember_authorization_request, only: :new
    before_action :load_authorization_request

    def new
    end

    def create
      return redirect_to_client(error: "access_denied", description: "The request was denied.") unless params[:approve].present?

      code = OauthAuthorizationCode.issue!(
        client: @client, user: current_user, redirect_uri: @redirect_uri,
        code_challenge: @code_challenge, scope: @scope, resource: params[:resource]
      )
      redirect_to_client(code: code.plaintext)
    end

    private

    # require_login! sends a signed-out visitor to the front page, which would
    # otherwise strand them there mid-connect: the client sent them here with a
    # URL full of parameters nobody can retype. Parked before that runs so the
    # HCB callback can bring them back to exactly this request.
    def remember_authorization_request
      session[:return_to] = request.fullpath unless current_user
    end

    def load_authorization_request
      @client = OauthClient.find_by(client_id: params[:client_id].to_s)
      @scope = granted_scope

      # A bad client_id or an unregistered redirect_uri is the one class of
      # error that must NOT be reported by redirecting: the only place to send
      # it is a URI we've just decided we can't trust. Show it here instead.
      return render_request_error("That app isn't registered with Steelyard.") unless @client

      @redirect_uri = requested_redirect_uri
      return render_request_error("That app asked to be sent somewhere it isn't registered to receive replies.") unless @redirect_uri

      @code_challenge = params[:code_challenge].to_s
      # Past this point errors go back to the client, which knows how to show
      # them to the user.
      return redirect_to_client(error: "unsupported_response_type", description: "Only the authorization code flow is supported.") unless params[:response_type] == "code"
      redirect_to_client(error: "invalid_request", description: "PKCE is required: send code_challenge with code_challenge_method=S256.") if @code_challenge.blank? || params[:code_challenge_method] != "S256"
    end

    def requested_redirect_uri
      requested = params[:redirect_uri].presence
      # A client with exactly one registered URI may omit it; anything else has
      # to say which one it means, and it has to be one it registered.
      return @client.redirect_uris.sole if requested.nil? && @client.redirect_uris.one?

      requested if requested && @client.permits_redirect?(requested)
    end

    # Only scopes this server actually issues, so a client asking for something
    # invented gets an honest answer about what it was given rather than a
    # token that claims more than it can do.
    def granted_scope
      requested = params[:scope].to_s.split
      granted = requested.any? ? (requested & Metadata::SCOPES) : Metadata::SCOPES
      granted.join(" ").presence || Metadata::DEFAULT_SCOPE
    end

    def redirect_to_client(code: nil, error: nil, description: nil)
      uri = URI.parse(@redirect_uri)
      query = Rack::Utils.parse_query(uri.query)
      query["code"] = code if code
      query["error"] = error if error
      query["error_description"] = description if description
      # Echoed back untouched: it's the client's CSRF defence for this flow.
      query["state"] = params[:state] if params[:state].present?
      uri.query = query.to_query

      redirect_to uri.to_s, allow_other_host: true
    end

    def render_request_error(message)
      render :error, status: :bad_request, locals: { message: message }
    end
  end
end
