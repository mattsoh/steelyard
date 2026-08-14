# Where a signed-in user mints and revokes the tokens that the v1 API and the
# MCP endpoint authenticate with. Session-authenticated like the rest of the
# web app -- a token can't be used to mint more tokens, which keeps a leaked
# one from being able to outlive its own revocation.
class ApiTokensController < ApplicationController
  def index
    @api_tokens = current_user.api_tokens.order(revoked_at: :asc, created_at: :desc)
  end

  def create
    token = ApiToken.mint!(user: current_user, name: params[:name])
    # The only moment the token itself exists outside the caller's hands -- only
    # its digest is stored, so it's shown once here and never again.
    flash[:new_api_token] = token.plaintext
    flash[:notice] = "Created #{token.name}."
    redirect_to api_tokens_path
  end

  def destroy
    token = current_user.api_tokens.active.find_by(id: params[:id])
    token&.revoke!
    redirect_to api_tokens_path, notice: token ? "Revoked #{token.name}." : "That token is already revoked."
  end
end
