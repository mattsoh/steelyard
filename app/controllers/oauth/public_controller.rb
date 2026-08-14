module Oauth
  # The endpoints an OAuth client talks to directly, with no user and no
  # session: discovery, registration, and the token exchange. Each is
  # authenticated (or not) by the OAuth protocol's own rules rather than by this
  # app's login, and each answers in JSON.
  class PublicController < ApplicationController
    skip_before_action :require_login!
    skip_forgery_protection

    before_action { request.format = :json }

    private

    def base_url = request.base_url

    def metadata = @metadata ||= Metadata.new(base_url)

    # RFC 6749 section 5.2: a machine-readable code, plus a sentence for
    # whoever is reading the logs when a connector won't connect.
    def render_oauth_error(error, description, status: :bad_request)
      response.set_header("Cache-Control", "no-store")
      render json: { error: error, error_description: description }, status: status
    end
  end
end
