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

      # One match with its change history. Answers for undone matches too --
      # see PublicApi::Operations#match.
      def show
        render json: operations.match(params[:organization_id], params[:id])
      end

      def create
        render json: operations.create_match(
          params[:organization_id],
          incoming_ids: params[:incoming_ids],
          outgoing_ids: params[:outgoing_ids],
          note: params[:note]
        ), status: :created
      end

      # Partial: a field the caller didn't send is left as it stands, so
      # correcting a note can't silently empty the legs. Hence params.key?
      # rather than reading the values straight out -- an absent field and one
      # sent as null have to arrive at the operation as the same nil.
      def update
        render json: operations.update_match(
          params[:organization_id], params[:id],
          incoming_ids: params.key?(:incoming_ids) ? params[:incoming_ids] : nil,
          outgoing_ids: params.key?(:outgoing_ids) ? params[:outgoing_ids] : nil,
          note: params.key?(:note) ? params[:note].to_s : nil
        )
      end

      # Undo rather than delete: the match is marked undone and its legs freed,
      # the same reversible operation the matcher's "Undo" button performs.
      def destroy
        render json: operations.undo_match(params[:organization_id], params[:id])
      end
    end
  end
end
