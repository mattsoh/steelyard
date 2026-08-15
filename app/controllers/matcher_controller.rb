class MatcherController < ApplicationController
  include OrganizationScoped
  layout "legacy"

  # Also serves /organizations/:id/matches/:match_id -- the same page, with the
  # match detail popup opened over it on load (see match_detail.js). The match
  # itself is fetched by that popup rather than rendered here, so a link to one
  # doesn't wait on the page's full transaction drain.
  def show
    @focus_match_id = params[:id]
  end
end
