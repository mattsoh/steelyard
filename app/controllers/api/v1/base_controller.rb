module Api
  module V1
    # The programmatic REST surface: same data and same rules as the browser
    # API under /organizations/:id/api, but authenticated with a token instead
    # of a session and shaped for callers that aren't this app's own frontend.
    # Every action is a thin wrapper over PublicApi::Operations, which the MCP
    # endpoint calls too.
    class BaseController < ApplicationController
      include TokenAuthenticated

      rescue_from PublicApi::Error do |error|
        render json: { error: error.message }, status: error.status
      end

      private

      def operations = @operations ||= PublicApi::Operations.new(current_user)

      def render_token_error(message, status)
        # Names the scheme the caller should have used, per RFC 6750 -- some
        # HTTP clients retry with credentials on the strength of this header.
        response.set_header("WWW-Authenticate", 'Bearer realm="steelyard"') if status == :unauthorized
        render json: { error: message }, status: status
      end
    end
  end
end
