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

  # An auditor is HCB's read-only admin: `admin` is false for them, and they're
  # let in on the strength of `auditor` alone.
  test "an auditor who isn't an admin can log in" do
    auditor = User.new(hcb_user_id: "usr_4", name: "Ari", email: "ari@example.com")

    sign_in_via_hcb!(auditor, admin: false, auditor: true)

    assert_redirected_to organizations_path
    assert_equal User.find_by!(hcb_user_id: "usr_4").id, session[:user_id]
  end

  # Steelyard is for HCB admins and auditors only, and the login callback is the
  # one place that's enforced -- so anyone else has to come out of it with
  # nothing: no session, no user row, no HCB tokens on file.
  test "a non-admin is turned away without an account being created" do
    newcomer = User.new(hcb_user_id: "usr_2", name: "Sam", email: "sam@example.com")

    assert_no_difference -> { User.count } do
      sign_in_via_hcb!(newcomer, admin: false)
    end

    assert_response :forbidden
    assert_includes response.body, "HCB admins"
    assert_nil session[:user_id]

    get organizations_path
    assert_redirected_to root_path
  end

  # Someone who had access and then lost admin on HCB: logging in again must
  # not refresh the HCB tokens on file, and must not leave them holding the
  # session they walked in with.
  test "a former admin can't log back in, and loses the session they had" do
    sign_in_via_hcb!(@user)
    assert_equal @user.id, session[:user_id]
    @user.update!(access_token: "stale")

    sign_in_via_hcb!(@user, admin: false)

    assert_response :forbidden
    assert_nil session[:user_id]
    assert_equal "stale", @user.reload.access_token
  end

  # HCB's payload is the only thing vouching for the visitor, so anything short
  # of an explicit `true` -- the keys missing entirely, say -- is a no.
  test "an identity with no admin or auditor flag is turned away" do
    ENV["HCB_OAUTH_REDIRECT_URI"] ||= "http://www.example.com/auth/hcb/callback"
    identity = { "id" => "usr_3", "email" => "pat@example.com", "name" => "Pat" }

    Hcb.stub(:oauth_client, FakeHcbOauth.new(identity)) do
      get login_path
      get hcb_callback_path, params: { code: "hcb-code", state: session[:oauth_state] }
    end

    assert_response :forbidden
    assert_nil User.find_by(hcb_user_id: "usr_3")
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
