require "test_helper"

class MatcherControllerTest < ActionController::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    session[:user_id] = @user.id
  end

  test "renders the legacy matcher shell for an org member" do
    stub_membership("member") do
      get :show, params: { organization_id: "org_1" }
    end

    assert_response :success
    assert_includes response.body, 'window.HCB_ORGANIZATION_ID = "org_1"'
    assert_includes response.body, 'id="list-incoming"'
    assert_includes response.body, 'id="list-outgoing"'
    assert_includes response.body, 'id="tray-body"'
    assert_includes response.body, 'id="btn-refresh-transactions"'
    assert_includes response.body, 'id="sync-note"'
    assert_includes response.body, "Loading transactions"
  end

  # The CSV exports are built client-side from rows the page has already
  # loaded, so all the server owes them is the buttons -- disabled, because
  # nothing is loaded yet when the shell is served.
  test "the CSV download buttons are rendered, disabled until data lands" do
    stub_membership("member") do
      get :show, params: { organization_id: "org_1" }
    end

    %w[
      btn-download-unmatched-in btn-download-unmatched-out
      btn-download-balanced btn-download-unbalanced
    ].each do |id|
      assert_match(/id="#{id}"[^>]*disabled/, response.body)
    end
  end

  test "the match modal is on the page, closed" do
    stub_membership("member") do
      get :show, params: { organization_id: "org_1" }
    end

    assert_match(/id="match-modal-overlay"[^>]*class="modal-overlay hidden"/, response.body)
    assert_includes response.body, "window.FOCUS_MATCH_ID = null"
  end

  # A link to one match: the same page, with that match's popup opened over it
  # on load. The match itself isn't rendered here -- match_detail.js fetches it,
  # so the popup doesn't wait on the page's transaction drain behind it.
  test "a match link renders the matcher with that match in focus" do
    stub_membership("member") do
      get :show, params: { organization_id: "org_1", id: "42" }
    end

    assert_response :success
    assert_includes response.body, 'window.FOCUS_MATCH_ID = "42"'
    assert_includes response.body, 'id="list-incoming"'
  end

  test "a non-member gets the same not-found response as a nonexistent org" do
    stub_membership(nil) do
      get :show, params: { organization_id: "org_1" }
    end
    assert_response :not_found

    # Including through a match link, which is the form of this URL most likely
    # to be forwarded to someone outside the organization.
    stub_membership(nil) do
      get :show, params: { organization_id: "org_1", id: "42" }
    end
    assert_response :not_found
  end

  test "unauthenticated visitors are redirected to login" do
    session[:user_id] = nil
    get :show, params: { organization_id: "org_1" }
    assert_redirected_to root_path
  end
end
