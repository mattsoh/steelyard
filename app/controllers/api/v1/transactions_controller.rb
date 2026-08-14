module Api
  module V1
    class TransactionsController < BaseController
      def index
        render json: operations.transactions(
          params[:organization_id],
          status: params[:status] || "all",
          direction: params[:direction],
          query: params[:query],
          after: params[:after],
          before: params[:before],
          min_amount: params[:min_amount],
          max_amount: params[:max_amount],
          include_before_cutoff: ActiveModel::Type::Boolean.new.cast(params[:include_before_cutoff]),
          limit: params[:limit],
          offset: params[:offset].to_i
        )
      end

      def show
        render json: operations.transaction(params[:organization_id], params[:id])
      end
    end
  end
end
