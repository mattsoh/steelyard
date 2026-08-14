module LegacyMigration
  # One-off importer for the pre-Rails app's data/matches.json,
  # data/manual_transactions.json, and data/ledger.json. Old integer/negative
  # ids only meant anything relative to that CSV snapshot, so each leg of
  # each legacy match is re-resolved against live HCB transactions by
  # date+amount, disambiguated by memo similarity when more than one
  # transaction matches. Manual (negative-id) legs become MatchAdjustments
  # instead, since they were never real bank transactions to begin with.
  class MatchImporter
    Report = Struct.new(:created, :skipped, :dry_run, keyword_init: true)

    IMPORTER_HCB_USER_ID = "legacy-import".freeze
    WHODUNNIT = "#{AuditVersion::SYSTEM_PREFIX}legacy_import".freeze
    DATE_WINDOW_DAYS = 3

    def initialize(client:, organization_id:, legacy_dir:, dry_run: true)
      @client = client
      @organization_id = organization_id
      @legacy_dir = legacy_dir
      @dry_run = dry_run
    end

    def call
      legacy_matches = read_json("matches.json")["matches"]
      legacy_by_id = read_json("ledger.json")["ledger"].index_by { |t| t["id"] }
      manual_by_id = read_json("manual_transactions.json")["transactions"].index_by { |t| t["id"] }

      live = Hcb::OrganizationTransactions.new(@client, @organization_id)
        .all(bypass_cache: true)
        .map { |t| Hcb::TransactionPresenter.new(t) }

      importer = find_or_create_importer_user
      # Live transactions already spoken for -- by matches created outside this
      # importer, or by earlier legs/matches within this same run -- so two
      # legacy legs with the same date+amount (e.g. duplicate-amount legs in a
      # batch disbursement) never resolve to the same live transaction twice.
      claimed = MatchTransaction.where(hcb_organization_id: @organization_id).pluck(:hcb_transaction_id).to_set
      created = 0
      skipped = []

      legacy_matches.each do |legacy_match|
        next if Match.exists?(legacy_id: legacy_match["id"])

        resolution = resolve_legs(legacy_match, legacy_by_id, manual_by_id, live, claimed)
        if resolution[:unresolved].any?
          unclaim(resolution, claimed)
          skipped << { legacy_id: legacy_match["id"], unresolved_legacy_leg_ids: resolution[:unresolved] }
          next
        end

        created += 1
        persist_match(legacy_match, resolution, importer) unless @dry_run
      end

      write_report(skipped)
      Report.new(created: created, skipped: skipped.size, dry_run: @dry_run)
    end

    private

    def read_json(filename)
      JSON.parse(File.read(File.join(@legacy_dir, filename)))
    end

    def find_or_create_importer_user
      User.find_or_create_by!(hcb_user_id: IMPORTER_HCB_USER_ID) do |u|
        u.name = "Migrated from legacy system"
        u.access_token = "n/a"
        u.refresh_token = "n/a"
        u.token_expires_at = 100.years.from_now
      end
    end

    def resolve_legs(legacy_match, legacy_by_id, manual_by_id, live, claimed)
      incoming = Array(legacy_match["incoming_ids"]).map { |id| resolve_leg(id, legacy_by_id, manual_by_id, live, claimed) }
      outgoing = Array(legacy_match["outgoing_ids"]).map { |id| resolve_leg(id, legacy_by_id, manual_by_id, live, claimed) }
      unresolved = (incoming + outgoing).select { |r| r[:type] == :unresolved }.map { |r| r[:legacy_id] }
      { incoming: incoming, outgoing: outgoing, unresolved: unresolved }
    end

    def unclaim(resolution, claimed)
      (resolution[:incoming] + resolution[:outgoing]).each do |r|
        claimed.delete(r[:hcb_transaction_id]) if r[:type] == :transaction
      end
    end

    def resolve_leg(legacy_id, legacy_by_id, manual_by_id, live, claimed)
      if legacy_id.negative? && manual_by_id.key?(legacy_id)
        manual = manual_by_id[legacy_id]
        return { type: :adjustment, legacy_id: legacy_id, amount: manual["amount"], memo: manual["memo"] }
      end

      legacy_tx = legacy_by_id[legacy_id]
      return { type: :unresolved, legacy_id: legacy_id } unless legacy_tx

      candidate = best_candidate(legacy_tx, live, claimed)
      return { type: :unresolved, legacy_id: legacy_id } unless candidate

      claimed << candidate.id
      { type: :transaction, legacy_id: legacy_id, hcb_transaction_id: candidate.id }
    end

    def best_candidate(legacy_tx, live, claimed)
      legacy_date = Date.parse(legacy_tx["date"])
      candidates = live.select do |t|
        !claimed.include?(t.id) &&
          (t.amount - legacy_tx["amount"]).abs < 0.005 && (Date.parse(t.date) - legacy_date).abs.to_i <= DATE_WINDOW_DAYS
      end
      candidates.max_by { |t| memo_similarity(t.memo, legacy_tx["memo"]) }
    end

    def memo_similarity(a, b)
      a_tokens = a.to_s.downcase.split(/\W+/).reject(&:empty?).to_set
      b_tokens = b.to_s.downcase.split(/\W+/).reject(&:empty?).to_set
      return 0.0 if a_tokens.empty? || b_tokens.empty?

      (a_tokens & b_tokens).size.to_f / (a_tokens | b_tokens).size
    end

    def persist_match(legacy_match, resolution, importer)
      # These matches predate this app; the versions written here are the
      # import itself, not anyone's decision. Naming the process keeps the
      # audit log honest about that instead of leaving whodunnit empty, which
      # reads the same as a change nobody could account for.
      PaperTrail.request(whodunnit: WHODUNNIT) do
        persist_match_records(legacy_match, resolution, importer)
      end
    end

    def persist_match_records(legacy_match, resolution, importer)
      ActiveRecord::Base.transaction do
        match = Match.create!(
          hcb_organization_id: @organization_id,
          note: legacy_match["note"].presence,
          discrepancy_cents: (legacy_match["discrepancy"].to_f * 100).round,
          created_by: importer,
          legacy_id: legacy_match["id"]
        )
        resolution[:incoming].each { |r| persist_leg(match, r, :incoming, importer) }
        resolution[:outgoing].each { |r| persist_leg(match, r, :outgoing, importer) }
      end
    end

    def persist_leg(match, resolved, direction, importer)
      case resolved[:type]
      when :transaction
        match.match_transactions.create!(
          hcb_organization_id: @organization_id, hcb_transaction_id: resolved[:hcb_transaction_id], direction: direction
        )
      when :adjustment
        match.adjustments.create!(amount_cents: (resolved[:amount] * 100).round, memo: resolved[:memo], created_by: importer)
      end
    end

    def write_report(skipped)
      return if skipped.empty?

      path = Rails.root.join("tmp", "legacy_migration", "unmatched_#{Process.pid}_#{skipped.hash.abs}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(skipped))
      Rails.logger.warn("[LegacyMigration] #{skipped.size} legacy match(es) had unresolved legs; see #{path}")
    end
  end
end
