module Oauth
  # Dynamic client registration (RFC 7591). Claude registers a fresh client
  # each time someone connects the server, so this has to be open -- but a
  # client record is inert on its own: it grants nothing until a signed-in user
  # approves it on the consent screen, and then only what that user can already
  # do. Rate-limited because it's the one unauthenticated endpoint here that
  # writes rows.
  class RegistrationsController < PublicController
    rate_limit to: 20, within: 1.minute,
      with: -> { render_oauth_error("invalid_request", "Too many registrations; try again shortly.", status: :too_many_requests) }

    def create
      body = registration_body
      return render_oauth_error("invalid_client_metadata", "Request body must be a JSON object.") unless body.is_a?(Hash)

      # A client that asks to authenticate with a secret gets one. Claude
      # doesn't ask: it registers as a public client and proves itself with
      # PKCE instead.
      secret = (SecureRandom.urlsafe_base64(32) if confidential?(body))
      client = OauthClient.register!(name: body["client_name"] || body["software_id"], redirect_uris: body["redirect_uris"], secret: secret)

      response.set_header("Cache-Control", "no-store")
      render json: registration_response(client, secret), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render_oauth_error("invalid_redirect_uri", e.record.errors.full_messages.to_sentence)
    end

    private

    # RFC 7591 says this endpoint takes application/json -- unlike the token
    # endpoint next door, which takes form encoding. Read from the raw body so
    # a client that sends the right content type but an array, or nothing at
    # all, gets an answer rather than an unexpected params shape.
    def registration_body
      JSON.parse(request.raw_post.presence || "null")
    rescue JSON::ParserError
      nil
    end

    def confidential?(body)
      method = body["token_endpoint_auth_method"]
      method.present? && method != "none"
    end

    def registration_response(client, secret)
      json = {
        client_id: client.client_id,
        client_id_issued_at: client.created_at.to_i,
        redirect_uris: client.redirect_uris,
        client_name: client.name,
        grant_types: [ "authorization_code", "refresh_token" ],
        response_types: [ "code" ],
        token_endpoint_auth_method: client.public_client? ? "none" : "client_secret_post",
        scope: Metadata::DEFAULT_SCOPE
      }
      # Returned once, here, and never recoverable afterwards -- only its
      # digest is stored.
      json[:client_secret] = secret if secret
      json
    end
  end
end
