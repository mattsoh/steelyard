class Api::MatchesController < ApplicationController
  include OrganizationScoped

  before_action :require_matcher_role!, only: [ :create, :update, :destroy ]

  def index
    ledger = OrganizationLedger.new(hcb_client, organization_id)
    matches = Match.active.for_organization(organization_id)
      .includes(:created_by, :match_transactions, :adjustments).order(:id)

    # An HCB transaction can change value after it was matched (see
    # Matches::Resync), so the stored discrepancy -- and the balanced/unbalanced
    # bucket the frontend sorts on -- is re-derived from current amounts before
    # serializing. This is the check that covers a plain page load and the
    # reload that follows a sync; the single-transaction refresh runs its own.
    Matches::Resync.new(ledger: ledger, matches: matches).call

    # One query for the whole page (see Matches::History.for_matches), which is
    # what lets every row say who last touched it without a query per row.
    histories = Matches::History.for_matches(matches)

    render json: { matches: matches.map { |m| serialize(m, ledger, history: histories[m.id]) } }
  end

  # Everything about one match, for the detail popup: its legs as full
  # transactions (rather than bare ids the caller has to already hold), who
  # made it, who last changed it, and the whole change history behind it.
  #
  # Undone matches are readable here, unlike everywhere else, because this is
  # the one view where "what happened to it" is the question -- a link to a
  # match someone undid should explain that rather than 404.
  def show
    match = Match.for_organization(organization_id)
      .includes(:created_by, :undone_by, :match_transactions, :adjustments)
      .find_by(id: params[:id])
    return render json: { error: "Match not found." }, status: :not_found unless match

    ledger = OrganizationLedger.new(hcb_client, organization_id)
    Matches::Resync.new(ledger: ledger, matches: [ match ]).call unless match.undone?

    history = Matches::History.for_match(match)

    render json: serialize(match, ledger, history: history).merge(
      undone_at: match.undone_at&.iso8601,
      undone_by_name: match.undone_by && display_name(match.undone_by),
      adjustments: match.adjustments.map { |a| { memo: a.memo, amount: a.amount_cents / 100.0 } },
      transactions: referenced_transactions(match, history, ledger),
      history: history.entries.map(&:as_json)
    )
  end

  def create
    incoming_ids = Array(params[:incoming_ids]).map(&:to_s)
    outgoing_ids = Array(params[:outgoing_ids]).map(&:to_s)

    # The legs being matched almost always came from the ledger the frontend
    # already rendered, so look them up there (served from the cached org
    # drain) instead of hitting HCB per id -- one HCB round trip per leg,
    # serialized, was adding seconds to a "simple" match. transaction_by_id
    # only falls back to a live HCB call when a leg isn't in the cache.
    ledger = OrganizationLedger.new(hcb_client, organization_id)
    by_id = (incoming_ids + outgoing_ids).uniq.index_with { |id| ledger.transaction_by_id(id) }

    result = Matches::Create.new(
      organization_id: organization_id,
      user: current_user,
      incoming_ids: incoming_ids,
      outgoing_ids: outgoing_ids,
      note: params[:note].to_s,
      transactions_by_id: by_id
    ).call

    if result.success?
      # Full serialized match, not just id/discrepancy, so the frontend can
      # splice it straight into its local match list instead of re-fetching
      # (and re-rendering) everything via a full reload.
      render json: serialize(result.match, ledger), status: :created
    else
      render json: { error: result.error }, status: result.status
    end
  end

  # Partial by design: a field that wasn't sent is left as it stands. The
  # matcher's edit flow sends the legs and the note together; the match popup's
  # note editor sends only a note, and must not disturb what the match pairs.
  def update
    match = Match.active.for_organization(organization_id).find_by(id: params[:id])
    incoming_ids = params.key?(:incoming_ids) ? Array(params[:incoming_ids]).map(&:to_s) : nil
    outgoing_ids = params.key?(:outgoing_ids) ? Array(params[:outgoing_ids]).map(&:to_s) : nil
    note = params.key?(:note) ? params[:note].to_s : nil

    ledger = OrganizationLedger.new(hcb_client, organization_id)
    # Nothing to resolve for a note-only save. Otherwise it's every leg the
    # match will have afterwards -- including the side that wasn't sent, whose
    # amounts still count toward the discrepancy.
    by_id = if match && (incoming_ids || outgoing_ids)
      ids = (incoming_ids || match.incoming_transaction_ids) + (outgoing_ids || match.outgoing_transaction_ids)
      ids.uniq.index_with { |id| ledger.transaction_by_id(id) }
    else
      {}
    end

    result = Matches::Update.new(
      match: match,
      user: current_user,
      incoming_ids: incoming_ids,
      outgoing_ids: outgoing_ids,
      note: note,
      transactions_by_id: by_id
    ).call

    if result.success?
      # With the history, so the popup that just saved a note can redraw its
      # "last edited by" line and its change log from this response rather than
      # fetching the match again.
      history = Matches::History.for_match(result.match)
      render json: serialize(result.match, ledger, history: history).merge(
        history: history.entries.map(&:as_json)
      )
    else
      render json: { error: result.error }, status: result.status
    end
  end

  def destroy
    match = Match.active.for_organization(organization_id).find_by(id: params[:id])
    result = Matches::Undo.new(match: match, user: current_user).call

    if result.success?
      render json: { ok: true }
    else
      render json: { error: result.error }, status: result.status
    end
  end

  private

  def serialize(m, ledger, history: nil)
    incoming_ids = m.incoming_transaction_ids
    outgoing_ids = m.outgoing_transaction_ids
    {
      id: m.id,
      incoming_ids: incoming_ids,
      outgoing_ids: outgoing_ids,
      note: m.note,
      discrepancy: m.discrepancy_cents / 100.0,
      created_by_name: display_name(m.created_by),
      created_at: m.created_at.iso8601,
      conflict: ledger.classify(incoming_ids + outgoing_ids) == :overlapping,
      undone: m.undone?,
      **last_edit_fields(history)
    }
  end

  # Who last touched the match and when, or nothing at all for one nobody has
  # touched since it was made -- which is most of them, and why the frontend
  # gets an explicit `edited` rather than having to infer it from timestamps.
  def last_edit_fields(history)
    edit = history&.last_edit
    return { edited: false } unless edit

    {
      edited: true,
      last_edited_at: edit.at.iso8601,
      last_edited_by_name: edit.actor_name,
      last_edited_action: edit.action.to_s
    }
  end

  # Every transaction the popup has to name: the match's own legs, plus the
  # ones its history mentions adding or removing, which by definition are no
  # longer legs and so wouldn't be resolved by anything else.
  #
  # Legs older than HCB's drained window are resolved through the ledger's
  # remote fallback, same as the matcher's own transaction list does it -- a
  # match from two years ago still has to name what it paired. That fallback
  # fetches as the person asking and caches per organization (see
  # OrganizationLedger.single_transaction_cache_key), so it cannot answer with
  # something fetched for an organization this one has no part in. A leg it
  # still can't resolve is reported unresolved; the popup says so in place of
  # the memo.
  def referenced_transactions(match, history, ledger)
    ids = (match.incoming_transaction_ids + match.outgoing_transaction_ids).uniq +
      history.entries.flat_map { |e| e.changes.filter_map { |c| c[:transaction_id] } }

    ids.uniq.index_with { |id| ledger.transaction_by_id(id) }
      .compact.transform_values(&:as_json)
  end

  def display_name(user) = user.name.presence || user.email
end
