module Api
  module V1
    class MatchesController < BaseController
      def index
        render json: operations.matches(
          params[:organization_id],
          status: params[:status] || "all",
          limit: params[:limit],
          offset: params[:offset].to_i
        )
      end

      def create
        render json: operations.create_match(
          params[:organization_id],
          incoming_ids: params[:incoming_ids],
          outgoing_ids: params[:outgoing_ids],
          note: params[:note]
        ), status: :created
      end

      # Undo rather than delete: the match is marked undone and its legs freed,
      # the same reversible operation the matcher's "Undo" button performs.
      def destroy
        render json: operations.undo_match(params[:organization_id], params[:id])
      end
    end
  end
end
