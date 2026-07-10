module Matches
  class Update
    Result = Struct.new(:success?, :match, :error, :status, keyword_init: true)

    def initialize(match:, user:, incoming_ids:, outgoing_ids:, note:, transactions_by_id:)
      @match = match
      @user = user
      @incoming_ids = incoming_ids
      @outgoing_ids = outgoing_ids
      @note = note
      @transactions_by_id = transactions_by_id
    end

    def call
      return failure("Match not found", :not_found) unless @match
      return failure("Match already undone", :not_found) if @match.undone?
      return failure("At least one of incoming_ids or outgoing_ids is required", :unprocessable_entity) if @incoming_ids.empty? && @outgoing_ids.empty?

      @incoming_ids.each do |id|
        t = @transactions_by_id[id]
        return failure("incoming_id #{id} is not a valid incoming transaction", :unprocessable_entity) unless t && !t.amount.negative?
      end
      @outgoing_ids.each do |id|
        t = @transactions_by_id[id]
        return failure("outgoing_id #{id} is not a valid outgoing transaction", :unprocessable_entity) unless t && t.amount.negative?
      end

      incoming_sum = @incoming_ids.sum { |id| @transactions_by_id[id].amount }
      outgoing_sum = @outgoing_ids.sum { |id| @transactions_by_id[id].amount }
      discrepancy = (incoming_sum + outgoing_sum).round(2)

      ActiveRecord::Base.transaction(requires_new: true) do
        @match.match_transactions.destroy_all
        @incoming_ids.each do |id|
          @match.match_transactions.create!(hcb_organization_id: @match.hcb_organization_id, hcb_transaction_id: id, direction: :incoming)
        end
        @outgoing_ids.each do |id|
          @match.match_transactions.create!(hcb_organization_id: @match.hcb_organization_id, hcb_transaction_id: id, direction: :outgoing)
        end
        @match.update!(note: @note, discrepancy_cents: (discrepancy * 100).round)
      end

      Result.new(success?: true, match: @match)
    rescue ActiveRecord::RecordNotUnique
      failure("One of these transactions was just matched by someone else. Refresh and try again.", :conflict)
    end

    private

    def failure(error, status)
      Result.new(success?: false, error: error, status: status)
    end
  end
end
