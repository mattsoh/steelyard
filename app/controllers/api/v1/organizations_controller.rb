module Api
  module V1
    class OrganizationsController < BaseController
      def index
        render json: { organizations: operations.organizations }
      end

      # The reconciliation state of one organization: where the cutoff sits,
      # what's still unmatched on each side, and how the confirmed matches
      # split. The first call after a cache expiry pays for the HCB drain
      # behind it, so it isn't free -- but it's one request rather than paging
      # the whole transaction list to count things.
      def show
        render json: operations.summary(params[:organization_id])
      end
    end
  end
end
