module Matches
  # Brings confirmed matches back in line with what HCB says now, and reports
  # what it had to change to do it.
  #
  # `discrepancy_cents` is a snapshot taken when the match was confirmed or last
  # edited, but HCB transactions aren't frozen once they've been drained: a
  # pending card charge settles at a different amount, a transfer is reversed, a
  # check is voided, a transaction is re-grouped under a different organization.
  # So a match saved as balanced can silently stop being balanced -- the matcher
  # buckets rows into "balanced" and "unbalanced" purely on the stored number --
  # and there are two distinct ways that happens:
  #
  #   * a leg's amount moved. The sum is re-derived and written, and the match
  #     may cross between balanced and unbalanced in either direction.
  #   * a leg stopped being part of this organization's history altogether.
  #     There is nothing left to sum it into, so the leg is dropped from the
  #     match and the discrepancy re-derived from what remains. A match whose
  #     legs all vanish is undone -- it isn't pairing anything any more.
  #
  # Both directions. A transaction remapped out of the organization drops its
  # leg; the same transaction remapped back *restores* it, and the discrepancy
  # is re-derived again with it counted. That's why a drop marks the leg
  # (`dropped_at`) rather than deleting it: the row is what remembers the match
  # ever paired that transaction, and deleting it would make somebody undoing
  # their own mistake on HCB unrecoverable here.
  #
  # Anything that brings fresh HCB values into view runs this: every
  # /api/matches load (which covers a page load, a full reload, and the "check
  # for new" sync) and the detail modal's single-transaction refresh. Cheap on
  # the common path -- leg amounts come from the same cached drain the caller
  # already materialized, and nothing is written unless something moved.
  #
  # Legs are looked up against the cached drain only (`remote: false`), which is
  # what keeps this affordable on an ordinary page load. Every leg was a real
  # drained transaction when the match was made -- Matches::Create validates
  # legs against the drain, and LegacyMigration::MatchImporter resolves each leg
  # to a drained transaction and turns anything it can't into a MatchAdjustment
  # -- so a leg the drain no longer contains has genuinely gone.
  class Resync
    Change = Struct.new(:match, :from_cents, :to_cents, keyword_init: true)

    # A match a leg was dropped from, with the discrepancy it moved to as a
    # result. `match_undone` when nothing was left to pair.
    Dropped = Struct.new(:match, :transaction_ids, :from_cents, :to_cents, :match_undone, keyword_init: true)

    # A match a previously-dropped leg came back to, because HCB accounts for
    # the transaction again.
    Restored = Struct.new(:match, :transaction_ids, :from_cents, :to_cents, keyword_init: true)

    # A match with legs the drain can't account for that were deliberately
    # *not* dropped, because too much went missing at once to believe HCB
    # rather than the drain. Nothing is written for these -- see
    # #safe_to_prune?.
    Unresolved = Struct.new(:match, :transaction_ids, keyword_init: true)

    Result = Struct.new(:changes, :dropped, :restored, :unresolved, keyword_init: true) do
      def any? = changes.any? || dropped.any? || restored.any? || unresolved.any?

      # Everything this resync did (or declined to do), in one shape, in dollars.
      #
      # One shape rather than three lists with three sets of keys: every surface
      # that reports a resync -- the matcher, the ledger, the detail modal, the
      # public API -- wants the same sentence out of it ("this match changed, and
      # here's how"), and they were each spelling it differently. `kind` is what
      # they branch on:
      #
      #   "amount"     -- a leg was restated; the discrepancy moved from -> to
      #   "dropped"    -- transaction_ids are no longer part of the match, and
      #                   the discrepancy moved to what's left. `undone` when
      #                   there was nothing left to pair
      #   "restored"   -- transaction_ids are part of the match again, having
      #                   previously been dropped, and the discrepancy moved to
      #                   include them
      #   "unresolved" -- transaction_ids don't resolve, and were deliberately
      #                   left in place (see #safe_to_prune?). Nothing moved, so
      #                   from/to are null: the stored discrepancy is the last
      #                   figure that could be worked out, not a current one
      def match_changes
        changes.map { |c| entry(c.match, "amount", from: c.from_cents, to: c.to_cents) } +
          dropped.map { |d| entry(d.match, "dropped", from: d.from_cents, to: d.to_cents, transaction_ids: d.transaction_ids, undone: d.match_undone) } +
          restored.map { |r| entry(r.match, "restored", from: r.from_cents, to: r.to_cents, transaction_ids: r.transaction_ids) } +
          unresolved.map { |u| entry(u.match, "unresolved", transaction_ids: u.transaction_ids) }
      end

      # Legs left in place that don't resolve, by match id. Carried on the match
      # itself as well as in #match_changes, because the change list explains
      # what just happened while these have to keep marking the row on every
      # later render.
      def unresolved_ids_by_match = unresolved.to_h { |u| [ u.match.id, u.transaction_ids ] }

      private

      def entry(match, kind, from: nil, to: nil, transaction_ids: [], undone: false)
        {
          id: match.id, kind: kind,
          from: from && from / 100.0, to: to && to / 100.0,
          transaction_ids: transaction_ids, undone: undone
        }
      end
    end

    # Dropping legs is destructive and it's driven by the *absence* of something
    # in a cache, which is a bad thing to trust unconditionally: a drain that
    # came back short would otherwise quietly gut every match in the
    # organization. So a mass disappearance is read as the drain being wrong
    # rather than HCB having lost hundreds of transactions, and reported instead
    # of applied.
    #
    # Below the floor, always prune -- one or two legs going is the ordinary
    # case this exists to handle, and in a small organization that can easily be
    # most of the legs there are.
    PRUNE_SAFETY_FLOOR = ENV.fetch("STEELYARD_RESYNC_PRUNE_FLOOR", 5).to_i
    PRUNE_SAFETY_FRACTION = ENV.fetch("STEELYARD_RESYNC_PRUNE_FRACTION", 0.25).to_f

    # Whoever happened to load the page didn't decide this match should change --
    # HCB restating or dropping a transaction did. Crediting them in the audit
    # log would read as an edit they never made, so the versions this writes
    # name the process instead.
    WHODUNNIT = "#{AuditVersion::SYSTEM_PREFIX}resync".freeze

    # One match's legs as they currently resolve, worked out before anything is
    # written so the whole batch can be judged (see #safe_to_prune?) first.
    # `returning` are legs previously dropped whose transactions are back.
    Plan = Struct.new(:match, :resolved, :missing, :returning, keyword_init: true)

    # `force_prune` applies drops the safety valve would otherwise refuse -- for
    # when the valve is wrong and somebody has looked at the matches and decided
    # so. See Api::MatchesController#prune.
    def initialize(ledger:, matches:, force_prune: false)
      @ledger = ledger
      @matches = matches
      @force_prune = force_prune
    end

    def call
      plans = @matches.map { |match| plan_for(match) }
      result = Result.new(changes: [], dropped: [], restored: [], unresolved: [])

      # Nothing missing anywhere is the overwhelmingly common case, and it never
      # needs the drain materialized or the batch judged.
      missing = plans.select { |plan| plan.missing.any? }
      # A leg that doesn't resolve and no drain to have missed it from are
      # indistinguishable from a single lookup, and the second happens for
      # ordinary reasons -- a full reload's purge, a drain that hasn't landed
      # yet. Acting on that would drop every leg of every match at once, so
      # nothing is concluded about missing legs at all until there's a drain to
      # conclude it from.
      missing = [] if missing.any? && !drain_present?
      prunable = missing.any? && (@force_prune || safe_to_prune?(plans, missing))

      PaperTrail.request(whodunnit: WHODUNNIT) do
        plans.each do |plan|
          # A leg coming back is applied before anything else about the match is
          # judged, so the discrepancy is re-derived once with it counted rather
          # than reported as an amount change and then again as a restore.
          if plan.returning.any?
            result.restored << restore(plan)
            next
          end

          if plan.missing.any?
            next unless missing.include?(plan)

            if prunable
              result.dropped << prune(plan)
            else
              result.unresolved << Unresolved.new(match: plan.match, transaction_ids: plan.missing)
            end
            next
          end

          change = resync_amounts(plan)
          result.changes << change if change
        end
      end

      result
    end

    private

    def plan_for(match)
      resolved = {}
      missing = []

      active_legs(match).each do |leg|
        amount = amount_of(leg)
        amount.nil? ? missing << leg.hcb_transaction_id : resolved[leg] = amount
      end

      # Legs dropped by an earlier resync whose transactions the drain accounts
      # for again -- somebody remapped one away on HCB and then back, and this
      # match should go back to saying what it said before.
      returning = dropped_legs(match).to_h { |leg| [ leg, amount_of(leg) ] }.compact

      Plan.new(match: match, resolved: resolved, missing: missing, returning: returning)
    end

    def amount_of(leg) = @ledger.transaction_by_id(leg.hcb_transaction_id, remote: false)&.amount_cents

    # Re-derives the discrepancy from amounts that all still resolve. nil when
    # it hasn't moved, which is almost always.
    def resync_amounts(plan)
      expected = plan.resolved.values.sum + adjustments_cents(plan.match)
      return nil if expected == plan.match.discrepancy_cents

      previous = plan.match.discrepancy_cents
      plan.match.update!(discrepancy_cents: expected)
      Change.new(match: plan.match, from_cents: previous, to_cents: expected)
    end

    # Drops the legs HCB no longer accounts for and re-derives what's left.
    #
    # The new discrepancy is whatever the surviving legs and adjustments come
    # to, which is the honest answer now that the dropped ones aren't part of
    # the match: a match can become balanced this way, or stop being balanced,
    # and either is a real change in what it claims rather than an artefact.
    def prune(plan)
      match = plan.match
      previous = match.discrepancy_cents
      expected = plan.resolved.values.sum + adjustments_cents(match)
      # Nothing left to pair. A zero-leg match would sit in the matcher looking
      # balanced while accounting for nothing at all, so it's undone -- by the
      # process, which is why there's no undone_by to name.
      emptied = plan.resolved.empty? && match.adjustments.empty?

      ActiveRecord::Base.transaction do
        # Marked one at a time rather than in bulk: the version that records
        # which leg went is written by callbacks a bulk update skips.
        dropped_at = Time.current
        active_legs(match).each do |leg|
          leg.update!(dropped_at: dropped_at) if plan.missing.include?(leg.hcb_transaction_id)
        end

        if emptied
          match.update!(undone_at: Time.current, discrepancy_cents: expected)
        else
          match.update!(discrepancy_cents: expected)
        end
      end

      Dropped.new(
        match: match, transaction_ids: plan.missing,
        from_cents: previous, to_cents: expected, match_undone: emptied
      )
    end

    # Puts previously-dropped legs back and re-derives the match with them
    # counted again. The mirror of #prune, and the reason a drop marks the row
    # rather than deleting it.
    def restore(plan)
      match = plan.match
      previous = match.discrepancy_cents
      expected = (plan.resolved.values + plan.returning.values).sum + adjustments_cents(match)
      # A match undone only because it had run out of legs is pairing something
      # again, so it comes back with them. One a person undid stays undone --
      # that was a decision, not a consequence.
      reinstate = match.undone? && match.undone_by_user_id.nil?

      ActiveRecord::Base.transaction do
        plan.returning.each_key { |leg| leg.update!(dropped_at: nil) }
        match.update!(discrepancy_cents: expected, **(reinstate ? { undone_at: nil } : {}))
      end

      Restored.new(
        match: match, transaction_ids: plan.returning.keys.map(&:hcb_transaction_id),
        from_cents: previous, to_cents: expected
      )
    end

    # Whether this batch's missing legs look like HCB dropping a few
    # transactions (apply it) or like the drain being wrong (report it).
    def safe_to_prune?(plans, missing_plans)
      missing_count = missing_plans.sum { |plan| plan.missing.size }
      return true if missing_count < PRUNE_SAFETY_FLOOR

      total_legs = plans.sum { |plan| plan.resolved.size + plan.missing.size }
      missing_count <= total_legs * PRUNE_SAFETY_FRACTION
    end

    def drain_present?
      return @drain_present if defined?(@drain_present)

      @drain_present = @ledger.transactions.any?
    end

    # Filtered in Ruby (not the model's scopes) so a caller that preloaded the
    # association doesn't get a fresh query per match -- same reasoning as
    # Match#incoming_transaction_ids.
    def active_legs(match) = match.match_transactions.select(&:live?)

    # Legs this match used to pair until HCB stopped accounting for them.
    def dropped_legs(match) = match.match_transactions.select { |leg| leg.undone_at.nil? && leg.dropped? }

    # Adjustments are the legacy importer's stand-ins for manual legs that were
    # never real HCB transactions (see LegacyMigration::MatchImporter). They're
    # part of what the match was originally judged balanced against, so leaving
    # them out here would flip every imported match that has one to "off by"
    # exactly that adjustment.
    def adjustments_cents(match) = match.adjustments.sum(&:amount_cents)
  end
end
