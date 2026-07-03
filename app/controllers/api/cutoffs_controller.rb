class Api::CutoffsController < ApplicationController
  include OrganizationScoped

  before_action :require_manager_role!

  def update
    ledger = OrganizationLedger.new(hcb_client, organization_id)
    result = Cutoffs::Update.new(
      organization_id: organization_id,
      user: current_user,
      ledger: ledger,
      transaction_id: params[:transaction_id].to_s,
      confirm: ActiveModel::Type::Boolean.new.cast(params[:confirm])
    ).call

    if result.success?
      render json: { ok: true, removed_match_ids: result.removed_match_ids }
    else
      render json: { error: result.error, conflicts: serialize_conflicts(result.conflicts, ledger) }, status: result.status
    end
  end

  private

  # Resolves each leg through the ledger (not the cached/windowed transaction
  # list) since a conflicting match may reference a transaction currently
  # hidden by the *existing* cutoff.
  def serialize_conflicts(matches, ledger)
    Array(matches).map do |m|
      {
        id: m.id,
        note: m.note,
        discrepancy: m.discrepancy_cents / 100.0,
        incoming: m.incoming_transaction_ids.filter_map { |id| ledger.transaction_by_id(id) }.map(&:as_json),
        outgoing: m.outgoing_transaction_ids.filter_map { |id| ledger.transaction_by_id(id) }.map(&:as_json)
      }
    end
  end
end
