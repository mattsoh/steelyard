require "test_helper"

class MatcherControllerTest < ActionController::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    session[:user_id] = @user.id
  end

  test "renders the legacy matcher shell for an org member" do
    Hcb::OrganizationMembers.stub :role_for, "member" do
      get :show, params: { organization_id: "org_1" }
    end

    assert_response :success
    assert_includes response.body, 'window.HCB_ORGANIZATION_ID = "org_1"'
    assert_includes response.body, 'id="list-incoming"'
    assert_includes response.body, 'id="list-outgoing"'
    assert_includes response.body, 'id="tray-body"'
    assert_includes response.body, "Loading transactions"
  end

  test "a non-member is forbidden" do
    Hcb::OrganizationMembers.stub :role_for, nil do
      get :show, params: { organization_id: "org_1" }
    end
    assert_response :forbidden
  end

  test "unauthenticated visitors are redirected to login" do
    session[:user_id] = nil
    get :show, params: { organization_id: "org_1" }
    assert_redirected_to login_path
  end
end
