module Cutoffs
  class Update
    Result = Struct.new(:success?, :error, :status, :conflicts, :removed_match_ids, keyword_init: true)

    def initialize(organization_id:, user:, ledger:, transaction_id:, confirm:)
      @organization_id = organization_id
      @user = user
      @ledger = ledger
      @transaction_id = transaction_id
      @confirm = confirm
    end

    def call
      option = @ledger.zero_options.find { |o| o.transaction_id == @transaction_id }
      return failure("Not a valid cutoff option", :unprocessable_entity) unless option

      conflicts = conflicting_matches(option.index)
      if conflicts.any? && !@confirm
        return Result.new(success?: false, error: "conflicts", status: :conflict, conflicts: conflicts)
      end

      removed_ids = []
      ActiveRecord::Base.transaction do
        conflicts.each do |match|
          # Re-select under FOR UPDATE rather than trust the in-memory copy
          # from the read above -- someone may have undone this match (via
          # the ordinary matcher UI) in between. Match.active filters it out
          # here if so, instead of us silently overwriting their undo.
          fresh = Match.active.for_organization(@organization_id).lock.find_by(id: match.id)
          next unless fresh

          result = Matches::Undo.new(match: fresh, user: @user).call
          removed_ids << fresh.id if result.success?
        end

        setting = OrganizationSetting.find_or_initialize_by(hcb_organization_id: @organization_id)
        setting.zero_balance_transaction_id = option.transaction_id
        setting.zero_balance_date = option.date
        setting.updated_by = @user
        setting.save!
      end

      Result.new(success?: true, removed_match_ids: removed_ids)
    rescue ActiveRecord::RecordNotUnique
      failure("Someone else just changed the cutoff. Refresh and try again.", :conflict)
    end

    private

    # Matches that would straddle the candidate cutoff -- part hidden, part
    # visible -- and so must be undone before the cutoff can move there.
    def conflicting_matches(candidate_index)
      ids_by_match = MatchTransaction.active.where(hcb_organization_id: @organization_id)
        .pluck(:match_id, :hcb_transaction_id)
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }

      return [] if ids_by_match.empty?

      conflicting_ids = ids_by_match.select { |_, ids| @ledger.classify(ids, cutoff: candidate_index) == :overlapping }.keys
      Match.active.for_organization(@organization_id).where(id: conflicting_ids).to_a
    end

    def failure(error, status)
      Result.new(success?: false, error: error, status: status)
    end
  end
end
