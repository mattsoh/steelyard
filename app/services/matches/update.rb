module Matches
  class Update
    Result = Struct.new(:success?, :match, :error, :status, keyword_init: true)

    # Every changeable part of a match is optional, and nil means "leave this
    # alone" rather than "empty it". That's what lets the match popup save a
    # note on its own -- the person writing one is not re-stating which
    # transactions the match pairs, and reading their silence as "no legs"
    # would empty the match.
    def initialize(match:, user:, incoming_ids: nil, outgoing_ids: nil, note: nil, transactions_by_id: {})
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

      incoming = @incoming_ids || @match.incoming_transaction_ids
      outgoing = @outgoing_ids || @match.outgoing_transaction_ids

      if replacing_legs?
        # Only a save that touches the legs can empty them. A note-only save is
        # left alone by this, which is what lets someone write about one of the
        # imported matches that stands entirely on adjustments and has no legs
        # of its own.
        return failure("At least one of incoming_ids or outgoing_ids is required", :unprocessable_entity) if incoming.empty? && outgoing.empty?

        incoming.each do |id|
          t = @transactions_by_id[id]
          return failure("incoming_id #{id} is not a valid incoming transaction", :unprocessable_entity) unless t && !t.amount.negative?
        end
        outgoing.each do |id|
          t = @transactions_by_id[id]
          return failure("outgoing_id #{id} is not a valid outgoing transaction", :unprocessable_entity) unless t && t.amount.negative?
        end
      end

      ActiveRecord::Base.transaction(requires_new: true) do
        replace_legs(incoming, outgoing) if replacing_legs?
        attributes = {}
        attributes[:note] = @note unless @note.nil?
        # Only when the legs moved: on a note-only save the stored discrepancy
        # is still the right answer, and re-deriving it here from a lookup the
        # caller never made would write a zero over it.
        attributes[:discrepancy_cents] = discrepancy_cents(incoming, outgoing) if replacing_legs?
        @match.update!(attributes) if attributes.any?
      end

      Result.new(success?: true, match: @match)
    rescue ActiveRecord::RecordNotUnique
      failure("One of these transactions was just matched by someone else. Refresh and try again.", :conflict)
    end

    private

    # Both sides are rewritten whenever either was given, so a caller that
    # sends only one side keeps the other exactly as it stands.
    def replacing_legs? = !(@incoming_ids.nil? && @outgoing_ids.nil?)

    def replace_legs(incoming, outgoing)
      @match.match_transactions.destroy_all
      incoming.each do |id|
        @match.match_transactions.create!(hcb_organization_id: @match.hcb_organization_id, hcb_transaction_id: id, direction: :incoming)
      end
      outgoing.each do |id|
        @match.match_transactions.create!(hcb_organization_id: @match.hcb_organization_id, hcb_transaction_id: id, direction: :outgoing)
      end
    end

    def discrepancy_cents(incoming, outgoing)
      sum = incoming.sum { |id| @transactions_by_id[id].amount } + outgoing.sum { |id| @transactions_by_id[id].amount }
      (sum.round(2) * 100).round
    end

    def failure(error, status)
      Result.new(success?: false, error: error, status: status)
    end
  end
end
