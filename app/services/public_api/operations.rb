module PublicApi
  # Everything a token-authenticated caller can do, in one place. The REST
  # controllers (Api::V1::*) and the MCP tools (Mcp::Tools) are both thin
  # adapters over this, so the two surfaces can't drift into answering the same
  # question differently.
  #
  # Membership and role are re-resolved here on every call rather than by a
  # controller before_action the way the browser API does it (see
  # OrganizationScoped): MCP has no per-request organization for a filter to
  # hang off -- the organization arrives inside each tool's arguments -- so the
  # check has to live with the operation itself. It costs nothing extra in
  # practice; Hcb::OrganizationMembers caches the lookup per organization.
  class Operations
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 500
    MATCHER_ROLES = %w[member manager].freeze

    Scope = Struct.new(:organization_id, :organization_slug, :role, :ledger, keyword_init: true)

    def initialize(user)
      @user = user
      @client = Hcb::Client.new(user)
    end

    # Every organization this token's owner can reach on HCB -- not every
    # organization Steelyard knows about, which isn't a thing a token should be
    # able to enumerate.
    def organizations
      response = @client.organizations
      list = response.is_a?(Hash) ? Array(response["data"]) : Array(response)
      list.map { |org| { id: org["id"], slug: org["slug"], name: org["name"] } }
    end

    # The figures the matcher header shows: what's left unexplained on each
    # side, and how the confirmed matches are split.
    def summary(organization_id)
      org = scope_for(organization_id)
      unmatched = unmatched_transactions(org)
      incoming, outgoing = unmatched.partition { |t| !t.amount_cents.negative? }
      records = resynced_matches(org)
      balanced, unbalanced = records.partition { |m| m.discrepancy_cents.zero? }
      matches_with_unresolved_legs = records.select { |m| unresolved_leg_ids(org, m).any? }
      cutoff = org.ledger.effective_cutoff

      {
        organization: organization_json(org),
        cutoff: { date: cutoff&.date, transaction_id: cutoff&.transaction_id },
        unmatched: {
          incoming_count: incoming.size,
          outgoing_count: outgoing.size,
          incoming_total: money(incoming.sum(&:amount_cents)),
          outgoing_total: money(outgoing.sum(&:amount_cents)),
          # What's still unexplained. Shrinks toward the organization's current
          # balance as matches are confirmed.
          net: money(unmatched.sum(&:amount_cents))
        },
        matches: {
          balanced: balanced.size,
          unbalanced: unbalanced.size,
          total_discrepancy: money(unbalanced.sum(&:discrepancy_cents)),
          # Counted separately rather than folded into the split above, because
          # these are the ones whose figures can't be trusted either way: a leg
          # HCB no longer has means the discrepancy couldn't be re-derived, so
          # whichever side it landed on is a stale claim.
          unresolved: matches_with_unresolved_legs.size
        }
      }
    end

    # Defaults to the matcher's working set -- transactions after the
    # zero-balance cutoff -- because that's the set the reconciliation is
    # actually about; `include_before_cutoff` opens it up to the full drained
    # history for callers auditing something older.
    def transactions(organization_id, status: "all", direction: nil, query: nil, after: nil, before: nil,
                     min_amount: nil, max_amount: nil, include_before_cutoff: false, limit: nil, offset: 0)
      org = scope_for(organization_id)
      match_ids = match_id_by_transaction(org)
      rows = include_before_cutoff ? org.ledger.transactions : org.ledger.after_cutoff

      rows = rows.select { |t| matches_status?(t, status, match_ids) }
      rows = rows.select { |t| matches_direction?(t, direction) }
      rows = rows.select { |t| matches_query?(t, query) }
      rows = rows.select { |t| in_date_range?(t, after, before) }
      rows = rows.select { |t| in_amount_range?(t, min_amount, max_amount) }
      # Newest first, the order both the matcher panels and the download default
      # to -- a caller paging through with `limit` sees recent activity first.
      rows = rows.reverse

      page, total = paginate(rows, limit, offset)
      {
        organization: organization_json(org),
        total: total,
        limit: page_size(limit),
        offset: offset.to_i,
        transactions: page.map { |t| transaction_json(t, match_ids) }
      }
    end

    # Restricted to the organization's own drained history on purpose. The
    # ledger can fall back to fetching an unknown id straight from HCB, which
    # would let this report a transaction belonging to some *other* organization
    # as though it were part of this one's reconciliation.
    def transaction(organization_id, transaction_id)
      org = scope_for(organization_id)
      found = org.ledger.transaction_by_id(transaction_id.to_s, remote: false)
      raise Error.new("No transaction #{transaction_id} in this organization's history.", status: :not_found) unless found

      transaction_json(found, match_id_by_transaction(org))
    end

    def matches(organization_id, status: "all", limit: nil, offset: 0)
      org = scope_for(organization_id)
      records = resynced_matches(org)
      records = records.select { |m| m.discrepancy_cents.zero? } if status.to_s == "balanced"
      records = records.reject { |m| m.discrepancy_cents.zero? } if status.to_s == "unbalanced"

      # Newest first, matching the order the matcher lists them in.
      page, total = paginate(records.reverse, limit, offset)
      # Only the page that's actually being serialized: one query either way,
      # but no reason to read the history of matches nobody asked for.
      histories = Matches::History.for_matches(page)
      {
        organization: organization_json(org),
        total: total,
        limit: page_size(limit),
        offset: offset.to_i,
        matches: page.map { |m| match_json(org, m, history: histories[m.id]) }
      }
    end

    # One match in full, including its change history: who made it, who has
    # touched it since, and what each of those changes actually did. The list
    # above says a match was edited; this says by whom and to what.
    #
    # Unlike every other read here, this can answer for an undone match --
    # "what happened to this one?" is exactly the question the history exists
    # for, and a match disappearing from the list is when people start asking.
    def match(organization_id, match_id)
      org = scope_for(organization_id)
      record = Match.for_organization(org.organization_id)
        .includes(:created_by, :undone_by, :match_transactions, :adjustments)
        .find_by(id: match_id)
      raise Error.new("No match #{match_id} in this organization.", status: :not_found) unless record

      # Same reasoning as resynced_matches, for the one record: report what the
      # match is off by now, not what it was off by when it was confirmed. An
      # undone match is left alone -- it isn't pairing anything any more.
      Matches::Resync.new(ledger: org.ledger, matches: [ record ]).call unless record.undone?
      history = Matches::History.for_match(record)

      match_json(org, record, history: history).merge(
        undone_at: record.undone_at&.iso8601,
        undone_by: record.undone_by && display_name(record.undone_by),
        adjustments: record.adjustments.map { |a| { memo: a.memo, amount: money(a.amount_cents) } },
        history: history.entries.map(&:as_json)
      )
    end

    def create_match(organization_id, incoming_ids:, outgoing_ids:, note: nil)
      org = scope_for(organization_id, needs: :matcher)
      incoming = id_list(incoming_ids, "incoming_ids")
      outgoing = id_list(outgoing_ids, "outgoing_ids")

      # Same lookup the browser API does: legs almost always come from the
      # cached drain, so this doesn't cost an HCB round trip per leg.
      by_id = org.ledger.write_legs_by_id(incoming + outgoing)
      result = Matches::Create.new(
        organization_id: org.organization_id,
        user: @user,
        incoming_ids: incoming,
        outgoing_ids: outgoing,
        note: note.to_s,
        transactions_by_id: by_id
      ).call
      raise Error.new(result.error, status: result.status) unless result.success?

      match_json(org, result.match)
    end

    # Partial by design, the same as the browser API's PATCH: a field left nil
    # is left as it stands rather than emptied, so a caller correcting a note
    # doesn't have to re-state which transactions the match pairs. Passing a
    # side rewrites that side; the other keeps its legs either way.
    def update_match(organization_id, match_id, incoming_ids: nil, outgoing_ids: nil, note: nil)
      org = scope_for(organization_id, needs: :matcher)
      match = Match.active.for_organization(org.organization_id).find_by(id: match_id)
      incoming = incoming_ids.nil? ? nil : id_list(incoming_ids, "incoming_ids")
      outgoing = outgoing_ids.nil? ? nil : id_list(outgoing_ids, "outgoing_ids")

      # Every leg the match will have afterwards, including the side that
      # wasn't sent -- its amounts still count toward the discrepancy. Nothing
      # to resolve at all for a note-only save.
      by_id = if match && (incoming || outgoing)
        ids = (incoming || match.incoming_transaction_ids) + (outgoing || match.outgoing_transaction_ids)
        org.ledger.write_legs_by_id(ids, existing: match.incoming_transaction_ids + match.outgoing_transaction_ids)
      else
        {}
      end

      result = Matches::Update.new(
        match: match,
        user: @user,
        incoming_ids: incoming,
        outgoing_ids: outgoing,
        note: note,
        transactions_by_id: by_id
      ).call
      raise Error.new(result.error, status: result.status) unless result.success?

      # With the history, since an edit has by definition just made one: the
      # caller sees its own change recorded rather than having to re-read the
      # match to find out how it was logged.
      history = Matches::History.for_match(result.match)
      match_json(org, result.match, history: history).merge(history: history.entries.map(&:as_json))
    end

    def undo_match(organization_id, match_id)
      org = scope_for(organization_id, needs: :matcher)
      match = Match.active.for_organization(org.organization_id).find_by(id: match_id)
      result = Matches::Undo.new(match: match, user: @user).call
      raise Error.new(result.error, status: result.status) unless result.success?

      { undone: true, match_id: match.id, organization: organization_json(org) }
    end

    private

    def scope_for(organization_id, needs: :reader)
      raise Error.new("organization_id is required.", status: :bad_request) if organization_id.blank?

      membership = Hcb::OrganizationMembers.role_for(
        client: @client, organization_id: organization_id.to_s, hcb_user_id: @user.hcb_user_id
      )
      # Deliberately the same answer whether the organization doesn't exist or
      # this token's owner simply isn't in it -- same reasoning as
      # OrganizationScoped#render_organization_not_found: telling the two apart
      # would let a token probe for organizations it can't see.
      raise Error.new("Organization not found.", status: :not_found) unless membership.role

      if needs == :matcher && !MATCHER_ROLES.include?(membership.role)
        raise Error.new("Only members and managers can change matches; this token's owner is a #{membership.role}.", status: :forbidden)
      end

      Scope.new(
        organization_id: membership.organization_id,
        organization_slug: membership.organization_slug,
        role: membership.role,
        ledger: OrganizationLedger.new(@client, membership.organization_id)
      )
    end

    # Said out loud rather than coerced: a caller that sent a bare string where
    # a list belongs has a bug, and silently reading it as "no legs on that
    # side" would answer with a match that isn't the one they asked for.
    def id_list(value, field)
      return [] if value.nil?
      raise Error.new("#{field} must be a list of transaction ids.", status: :bad_request) unless value.is_a?(Array)

      value.map(&:to_s)
    end

    def organization_json(org)
      { id: org.organization_id, slug: org.organization_slug, role: org.role }
    end

    def transaction_json(presenter, match_ids)
      match_id = match_ids[presenter.id]
      presenter.as_json.merge(matched: !match_id.nil?, match_id: match_id)
    end

    def match_json(org, match, history: nil)
      incoming_ids = match.incoming_transaction_ids
      outgoing_ids = match.outgoing_transaction_ids
      {
        id: match.id,
        organization_id: org.organization_id,
        discrepancy: money(match.discrepancy_cents),
        balanced: match.discrepancy_cents.zero?,
        # Legs that are no longer part of the organization's history on HCB.
        # When this isn't empty the discrepancy above (and so `balanced`) is the
        # last figure that could be worked out, not a current one -- the sum
        # can't be re-derived while a leg is missing, and guessing it from the
        # legs that remain would present a fiction as freshly confirmed.
        unresolved_ids: unresolved_leg_ids(org, match),
        undone: match.undone?,
        # Somebody decided this one doesn't need looking at again -- usually a
        # discrepancy that's a bug rather than missing money. It still counts
        # in the summary's totals; hiding only takes it out of the matcher's
        # lists by default.
        hidden: match.hidden?,
        note: match.note,
        created_by: display_name(match.created_by),
        created_at: match.created_at.iso8601,
        **last_edit_json(history),
        # A match with legs on both sides of the cutoff: half of it is in the
        # working set and half is settled history.
        spans_cutoff: org.ledger.classify(incoming_ids + outgoing_ids) == :overlapping,
        incoming_ids: incoming_ids,
        outgoing_ids: outgoing_ids,
        # The legs spelled out as well as listed by id -- a caller deciding
        # whether a match is right shouldn't have to fetch each leg separately.
        incoming: legs_json(org, incoming_ids),
        outgoing: legs_json(org, outgoing_ids)
      }
    end

    # Who last touched the match and when -- `edited: false` on its own for one
    # nobody has touched since it was made, which is most of them, so a caller
    # can tell "unchanged" from "changed" without comparing timestamps. Also
    # the answer for a match create_match has just returned, which passes no
    # history because it cannot have one yet.
    def last_edit_json(history)
      edit = history&.last_edit
      return { edited: false } unless edit

      { edited: true, last_edited_at: edit.at.iso8601, last_edited_by: edit.actor_name, last_edited_action: edit.action.to_s }
    end

    def display_name(user) = user.name.presence || user.email

    # `remote: false`: a leg the drain doesn't know about is reported as such
    # rather than paid for with a live HCB request per unresolvable id.
    def legs_json(org, ids)
      ids.map do |id|
        t = org.ledger.transaction_by_id(id, remote: false)
        next { id: id, loaded: false } unless t

        { id: t.id, date: t.date, memo: t.memo, amount: t.amount }
      end
    end

    def resynced_matches(org)
      records = Match.active.for_organization(org.organization_id)
        .includes(:created_by, :match_transactions, :adjustments).order(:id).to_a
      # An HCB transaction can change value after it was matched, so the stored
      # discrepancy -- and the balanced/unbalanced split derived from it -- is
      # re-derived from current amounts before anything is reported. Mutates the
      # records in place, so the values serialized below are the fresh ones.
      resync = Matches::Resync.new(ledger: org.ledger, matches: records).call

      # Legs HCB no longer accounts for that were deliberately left in place
      # (see Matches::Resync#safe_to_prune?). Those matches keep whatever
      # discrepancy they were last able to compute, so `balanced: true` on one
      # of them is a stale claim rather than a current fact -- remembered per
      # organization so everything serialized below can say so.
      @unresolved_leg_ids ||= {}
      @unresolved_leg_ids[org.organization_id] = resync.unresolved.to_h { |u| [ u.match.id, u.transaction_ids ] }

      # A prune destroys leg rows and can undo a match outright, neither of
      # which the already-loaded records know about -- serializing them would
      # report legs that have just been removed. Re-read instead.
      return records if resync.dropped.empty?

      Match.active.for_organization(org.organization_id)
        .includes(:created_by, :match_transactions, :adjustments).order(:id).to_a
    end

    # Legs of this match HCB no longer accounts for, as of the last resync for
    # its organization. Empty unless #resynced_matches has run for that
    # organization on this instance -- every path that serializes a match goes
    # through it.
    def unresolved_leg_ids(org, match)
      @unresolved_leg_ids&.dig(org.organization_id, match.id) || []
    end

    def unmatched_transactions(org)
      used = match_id_by_transaction(org)
      org.ledger.after_cutoff.reject { |t| used.key?(t.id) }
    end

    def match_id_by_transaction(org)
      @match_id_by_transaction ||= {}
      @match_id_by_transaction[org.organization_id] ||=
        MatchTransaction.active.where(hcb_organization_id: org.organization_id)
          .pluck(:hcb_transaction_id, :match_id).to_h
    end

    def matches_status?(transaction, status, match_ids)
      case status.to_s
      when "unmatched" then !match_ids.key?(transaction.id)
      when "matched" then match_ids.key?(transaction.id)
      else true
      end
    end

    def matches_direction?(transaction, direction)
      case direction.to_s
      when "in", "incoming" then !transaction.amount_cents.negative?
      when "out", "outgoing" then transaction.amount_cents.negative?
      else true
      end
    end

    # Matches the memo or the HCB code, so a code pasted from HCB's own UI finds
    # the transaction without anyone having to know its memo -- the same rule
    # the matcher's search box uses.
    def matches_query?(transaction, query)
      needle = query.to_s.strip.downcase
      return true if needle.empty?

      transaction.memo.to_s.downcase.include?(needle) || transaction.id.to_s.downcase.include?(needle)
    end

    # Dates are "YYYY-MM-DD" on both sides, so string comparison orders them
    # correctly without parsing. Both bounds are inclusive.
    def in_date_range?(transaction, after, before)
      return false if after.present? && transaction.date.to_s < after.to_s
      return false if before.present? && transaction.date.to_s > before.to_s

      true
    end

    # Compared on magnitude, so a caller looking for "$250" finds both the
    # donation and the grant that paid it out without having to know the sign.
    def in_amount_range?(transaction, min_amount, max_amount)
      magnitude = transaction.amount.abs
      return false if min_amount.present? && magnitude < min_amount.to_f
      return false if max_amount.present? && magnitude > max_amount.to_f

      true
    end

    def paginate(rows, limit, offset)
      [ rows.drop(offset.to_i).first(page_size(limit)), rows.size ]
    end

    def page_size(limit)
      requested = limit.presence&.to_i || DEFAULT_LIMIT
      requested.clamp(1, MAX_LIMIT)
    end

    def money(cents) = (cents.to_i / 100.0).round(2)
  end
end
