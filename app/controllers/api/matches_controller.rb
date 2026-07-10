class Api::MatchesController < ApplicationController
  include OrganizationScoped

  before_action :require_matcher_role!, only: [ :create, :update, :destroy ]

  def index
    ledger = OrganizationLedger.new(hcb_client, organization_id)
    matches = Match.active.for_organization(organization_id).includes(:created_by, :match_transactions).order(:id)
    render json: { matches: matches.map { |m| serialize(m, ledger) } }
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

  def update
    match = Match.active.for_organization(organization_id).find_by(id: params[:id])
    incoming_ids = Array(params[:incoming_ids]).map(&:to_s)
    outgoing_ids = Array(params[:outgoing_ids]).map(&:to_s)

    ledger = OrganizationLedger.new(hcb_client, organization_id)
    by_id = (incoming_ids + outgoing_ids).uniq.index_with { |id| ledger.transaction_by_id(id) }

    result = Matches::Update.new(
      match: match,
      user: current_user,
      incoming_ids: incoming_ids,
      outgoing_ids: outgoing_ids,
      note: params[:note].to_s,
      transactions_by_id: by_id
    ).call

    if result.success?
      render json: serialize(result.match, ledger)
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

  def serialize(m, ledger)
    incoming_ids = m.incoming_transaction_ids
    outgoing_ids = m.outgoing_transaction_ids
    {
      id: m.id,
      incoming_ids: incoming_ids,
      outgoing_ids: outgoing_ids,
      note: m.note,
      discrepancy: m.discrepancy_cents / 100.0,
      created_by_name: m.created_by.name.presence || m.created_by.email,
      created_at: m.created_at.iso8601,
      conflict: ledger.classify(incoming_ids + outgoing_ids) == :overlapping
    }
  end
end
