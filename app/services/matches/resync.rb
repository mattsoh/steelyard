module Matches
  # Re-derives a match's discrepancy from the transaction amounts as they stand
  # *now*.
  #
  # `discrepancy_cents` is a snapshot taken when the match was confirmed or last
  # edited, but HCB transactions aren't frozen once they've been drained: a
  # pending card charge settles at a different amount, a transfer is reversed, a
  # check is voided. So a match saved as balanced can silently stop being
  # balanced, and nothing in the app would ever notice -- the matcher buckets
  # rows into "balanced" and "unbalanced" purely on the stored number.
  #
  # Anything that brings fresh HCB values into view runs this: every
  # /api/matches load (which covers a page load, a full reload, and the "check
  # for new" sync) and the detail modal's single-transaction refresh. Cheap --
  # leg amounts come from the same cached drain the caller already materialized,
  # and only genuinely changed matches are written.
  #
  # A match with a leg that can't be resolved at all is left alone rather than
  # summed without it: a partial sum would replace a stale number with a wrong
  # one, and present it as freshly confirmed. Legs are looked up against the
  # cached drain only (`remote: false`) -- an id the organization's own history
  # doesn't contain is one of those unresolvable legs, and this runs often
  # enough that falling back to a live HCB request per unknown id would be a
  # slow surprise on an ordinary page load.
  class Resync
    Change = Struct.new(:match, :from_cents, :to_cents, keyword_init: true)

    # Whoever happened to load the page didn't decide this match's discrepancy
    # should move -- HCB restating a transaction did. Crediting them in the
    # audit log would read as an edit they never made, so the versions this
    # writes name the process instead.
    WHODUNNIT = "#{AuditVersion::SYSTEM_PREFIX}resync".freeze

    def initialize(ledger:, matches:)
      @ledger = ledger
      @matches = matches
    end

    # Returns one Change per match whose discrepancy actually moved (empty when
    # everything still adds up, which is the overwhelmingly common case).
    def call
      PaperTrail.request(whodunnit: WHODUNNIT) do
        @matches.filter_map { |match| resync(match) }
      end
    end

    private

    def resync(match)
      amounts = active_legs(match).map { |mt| @ledger.transaction_by_id(mt.hcb_transaction_id, remote: false)&.amount_cents }
      return nil if amounts.any?(&:nil?)

      expected = amounts.sum + adjustments_cents(match)
      return nil if expected == match.discrepancy_cents

      previous = match.discrepancy_cents
      match.update!(discrepancy_cents: expected)
      Change.new(match: match, from_cents: previous, to_cents: expected)
    end

    # Filtered in Ruby (not `match_transactions.active`) so a caller that
    # preloaded the association doesn't get a fresh query per match -- same
    # reasoning as Match#incoming_transaction_ids.
    def active_legs(match) = match.match_transactions.reject { |mt| mt.undone_at }

    # Adjustments are the legacy importer's stand-ins for manual legs that were
    # never real HCB transactions (see LegacyMigration::MatchImporter). They're
    # part of what the match was originally judged balanced against, so leaving
    # them out here would flip every imported match that has one to "off by"
    # exactly that adjustment.
    def adjustments_cents(match) = match.adjustments.sum(&:amount_cents)
  end
end
