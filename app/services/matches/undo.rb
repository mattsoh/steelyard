module Matches
  class Undo
    Result = Struct.new(:success?, :error, :status, keyword_init: true)

    def initialize(match:, user:)
      @match = match
      @user = user
    end

    def call
      return failure("Match not found", :not_found) unless @match
      return failure("Match already undone", :not_found) if @match.undone?

      ActiveRecord::Base.transaction do
        undone_at = Time.current
        @match.update!(undone_at: undone_at, undone_by: @user)
        # One update! per leg rather than a single `update_all`: bulk updates
        # skip callbacks, so the legs would be missing from the audit log even
        # though the match's own undo is in it -- and the legs are the part you
        # actually need when reconstructing what a match used to pair. A match
        # has a handful of them.
        @match.match_transactions.active.each { |mt| mt.update!(undone_at: undone_at) }
      end
      Result.new(success?: true)
    end

    private

    def failure(error, status)
      Result.new(success?: false, error: error, status: status)
    end
  end
end
