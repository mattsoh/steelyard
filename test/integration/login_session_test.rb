require "test_helper"

class LoginSessionTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(hcb_user_id: "usr_1", name: "Matt", email: "matt@example.com",
                         access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
  end

  # A session cookie the visitor was carrying before they logged in -- planted on
  # a shared machine, or by an attacker who got a Set-Cookie in first -- must not
  # be the session that comes out the other side holding an authenticated
  # user_id.
  test "logging in starts a new session rather than adopting the visitor's" do
    get login_path
    before = session.id

    assert before.present?, "expected the pre-login request to establish a session"

    sign_in_via_hcb!(@user)

    assert_equal @user.id, session[:user_id]
    assert_not_equal before, session.id
  end

  # The one thing that does have to survive the boundary: where the visitor was
  # headed. A client sends people to the consent screen with a URL full of
  # parameters nobody could retype, so losing it strands them on the front page
  # mid-connect.
  test "the parked destination survives the new session" do
    # Signed out, so the consent screen parks the request and sends the visitor
    # off to log in.
    get oauth_authorize_path, params: { client_id: "unregistered" }
    assert_redirected_to root_path

    sign_in_via_hcb!(@user)

    assert_redirected_to "/oauth/authorize?client_id=unregistered"
  end

  test "logging out clears the session and the stored HCB tokens" do
    sign_in_via_hcb!(@user)
    assert_equal @user.id, session[:user_id]

    delete logout_path

    assert_redirected_to root_path
    assert_nil session[:user_id]
    assert_nil @user.reload.access_token
    assert_nil @user.refresh_token
  end
end
