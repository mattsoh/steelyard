module Matches
  # Reads the change log (see AuditVersion) back as something a person can
  # read: who did what to a match, in the order it happened.
  #
  # One action doesn't write one version. Matches::Update replaces every leg
  # and then saves the match, so a single click leaves half a dozen rows
  # behind -- shown raw, "changed the outgoing side" would read as five
  # separate edits. They're regrouped here into one entry per action, keyed on
  # the request that wrote them (which is exactly why versions carry a
  # request_id at all). Versions written outside a request -- the legacy
  # importer's rake task -- have no request id to group on, so consecutive
  # rows by the same actor within a couple of seconds are treated as one
  # action, which is what a single pass of the importer looks like.
  #
  # Reading only. Nothing here decides application behaviour; a match still
  # *is* whatever its own columns say.
  class History
    # Group boundary for versions with no request id. Generous enough to hold
    # a burst that straddles a second boundary, far short of two separate
    # things a person did.
    BURST_WINDOW = 2.seconds

    # Match-level columns worth reporting a change to, and what to call them.
    # Everything else on the row is either bookkeeping (updated_at) or already
    # the entry's own headline (undone_at, undone_by_user_id).
    FIELDS = {
      "note" => { label: "Note", kind: "text" },
      "discrepancy_cents" => { label: "Discrepancy", kind: "amount" },
      # When, exactly, somebody hid it is on the match itself; what the history
      # is for here is that they did, so it reads as a yes/no rather than as a
      # timestamp appearing out of nowhere.
      "hidden_at" => { label: "Hidden from the match lists", kind: "flag" }
    }.freeze

    CHILD_TYPES = %w[MatchTransaction MatchAdjustment].freeze

    # Which match a leg/adjustment version belongs to. `object` holds the
    # record's state *before* the change, so an update or a destroy carries it;
    # a create has only `object_changes`, where each value is [before, after].
    # It has to come out of the version either way -- an edit destroys its legs,
    # so by the time anyone reads this there's no row left to join to.
    CHILD_MATCH_ID_SQL = "COALESCE(object ->> 'match_id', object_changes -> 'match_id' ->> 1)".freeze

    Entry = Struct.new(:at, :actor_name, :system, :action, :changes, keyword_init: true) do
      def as_json(*)
        { at: at.iso8601, actor_name: actor_name, system: system, action: action.to_s, changes: changes }
      end
    end

    def self.for_match(match)
      new(match_id: match.id, versions: versions_for([ match.id ]).to_a)
    end

    # One query for a whole page of matches, so the matcher's match list can
    # say who last touched each one without a query per row.
    def self.for_matches(matches)
      ids = matches.map(&:id)
      return {} if ids.empty?

      grouped = versions_for(ids).group_by { |v| owner_id(v) }
      ids.index_with { |id| new(match_id: id, versions: grouped.fetch(id, [])) }
    end

    def self.versions_for(ids)
      AuditVersion.where(
        "(item_type = 'Match' AND item_id IN (:ids)) OR " \
        "(item_type IN (:child_types) AND #{CHILD_MATCH_ID_SQL} IN (:ids_as_text))",
        ids: ids, child_types: CHILD_TYPES, ids_as_text: ids.map(&:to_s)
      ).order(:created_at, :id)
    end

    def self.owner_id(version)
      return version.item_id if version.item_type == "Match"

      (version.object&.dig("match_id") || version.object_changes&.dig("match_id")&.last).to_i
    end

    def initialize(match_id:, versions:)
      @match_id = match_id
      @versions = versions
    end

    # Oldest first, the order the actions happened in.
    def entries
      @entries ||= begin
        preload_actors!
        bursts.map { |burst| entry_for(burst) }
      end
    end

    def created_entry = entries.find { |e| e.action == :created }

    # The most recent thing that happened to the match after it was created --
    # nil for a match nobody has touched since, which is most of them.
    def last_edit = entries.reverse.find { |e| e.action != :created }

    private

    # AuditVersion#user looks its person up one version at a time; resolve them
    # all at once and hand the answers back, so a page of matches costs one
    # query rather than one per version.
    def preload_actors!
      ids = @versions.reject(&:system?).filter_map { |v| v.whodunnit.presence }.uniq
      return if ids.empty?

      users = User.where(id: ids).index_by { |u| u.id.to_s }
      @versions.each do |v|
        user = users[v.whodunnit]
        v.user = user if user
      end
    end

    def bursts
      @versions.each_with_object([]) do |version, acc|
        if acc.last && same_action?(acc.last, version)
          acc.last << version
        else
          acc << [ version ]
        end
      end
    end

    def same_action?(burst, version)
      first = burst.first
      return false unless first.whodunnit == version.whodunnit
      return first.request_id == version.request_id if first.request_id.present? || version.request_id.present?

      # No request to group on, so fall back to a burst of changes by the same
      # actor. One record can only change once per action, though -- a second
      # version of something already in the burst is a second thing happening,
      # however close together the two were.
      return false if burst.any? { |v| v.item_type == version.item_type && v.item_id == version.item_id }

      version.created_at - burst.last.created_at <= BURST_WINDOW
    end

    def entry_for(burst)
      match_versions = burst.select { |v| v.item_type == "Match" }
      Entry.new(
        at: burst.first.created_at,
        actor_name: burst.first.actor_name,
        system: burst.first.system?,
        action: action_for(burst, match_versions),
        changes: leg_changes(burst) + adjustment_changes(burst) + field_changes(match_versions)
      )
    end

    def action_for(burst, match_versions)
      return :created if match_versions.any? { |v| v.event == "create" }
      return :undone if match_versions.any? { |v| undone_here?(v) }
      # Nobody asked for this one: Matches::Resync re-derived the discrepancy
      # because HCB restated a transaction underneath the match.
      return :resynced if burst.first.system?

      :edited
    end

    def undone_here?(version)
      change = version.object_changes&.dig("undone_at")
      change.present? && change[1].present?
    end

    def leg_changes(burst)
      legs = burst.select { |v| v.item_type == "MatchTransaction" }
      added = legs.select { |v| v.event == "create" }.map { |v| leg_key(v) }
      removed = legs.select { |v| v.event == "destroy" }.map { |v| leg_key(v) }

      # An edit destroys and recreates every leg, changed or not (see
      # Matches::Update), so a leg that survived the edit untouched turns up on
      # both lists. Only the difference is something that actually happened.
      unchanged = added & removed

      (removed - unchanged).map { |key| leg_change("removed", key) } +
        (added - unchanged).map { |key| leg_change("added", key) }
    end

    def leg_key(version)
      [ leg_attribute(version, "hcb_transaction_id"), direction_name(leg_attribute(version, "direction")) ]
    end

    # A leg's direction is written to the log as whatever the enum happened to
    # serialize as -- the name from a create's `object_changes`, the stored
    # integer from a destroy's `object`. Normalized on the way in, so the two
    # halves of an edit compare as the same leg rather than reading as one
    # removed and a different one added.
    def direction_name(value)
      return MatchTransaction.directions.key(value) || "incoming" if value.is_a?(Integer)

      MatchTransaction.directions.key?(value.to_s) ? value.to_s : "incoming"
    end

    def leg_change(action, (transaction_id, direction))
      { kind: "leg", action: action, direction: direction, transaction_id: transaction_id }
    end

    # The value the record had for this version's event: what was created, or
    # what was there before it was destroyed.
    def leg_attribute(version, key)
      return version.object_changes&.dig(key)&.last if version.event == "create"

      version.object&.dig(key) || version.object_changes&.dig(key)&.first
    end

    # Only the legacy importer creates these (they stand in for legs that were
    # never real HCB transactions), but they're part of what a match balances
    # against, so a history that omitted them wouldn't add up.
    def adjustment_changes(burst)
      burst.select { |v| v.item_type == "MatchAdjustment" && v.event == "create" }.map do |v|
        {
          kind: "adjustment",
          memo: leg_attribute(v, "memo"),
          amount: leg_attribute(v, "amount_cents").to_i / 100.0
        }
      end
    end

    def field_changes(match_versions)
      match_versions.flat_map do |version|
        (version.object_changes || {}).filter_map do |column, (before, after)|
          field = FIELDS[column]
          next if field.nil? || before == after

          { kind: field[:kind], label: field[:label], from: display(field[:kind], before), to: display(field[:kind], after) }
        end
      end
    end

    def display(kind, value)
      return value.to_i / 100.0 if kind == "amount"
      return value.present? ? "yes" : "no" if kind == "flag"

      value
    end
  end
end
