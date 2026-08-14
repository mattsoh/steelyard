module Api
  module V1
    # Who a token belongs to. Exists so a caller wiring one up can prove it
    # works without having to guess at an organization id first.
    class MeController < BaseController
      def show
        render json: {
          user: { id: current_user.id, name: current_user.name, email: current_user.email, hcb_user_id: current_user.hcb_user_id },
          token: { name: @api_token.name, created_at: @api_token.created_at.iso8601 }
        }
      end
    end
  end
end
