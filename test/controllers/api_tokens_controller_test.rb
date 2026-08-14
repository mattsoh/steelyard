require "test_helper"

class ApiTokensControllerTest < ActionController::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    session[:user_id] = @user.id
  end

  test "unauthenticated visitors are redirected to login" do
    session[:user_id] = nil
    get :index
    assert_redirected_to root_path
  end

  test "creating a token shows it once and only once" do
    post :create, params: { name: "laptop" }

    assert_redirected_to api_tokens_path
    plaintext = flash[:new_api_token]
    assert plaintext.start_with?(ApiToken::PREFIX)
    assert_equal @user.api_tokens.sole, ApiToken.authenticate(plaintext)

    # The page it redirects to is the one showing the token, and the flash is
    # swept once it has: by the next visit there is nowhere left to read it
    # from, because only the digest was ever stored.
    get :index
    assert_response :success
    assert_equal plaintext, flash[:new_api_token]

    get :index
    assert_nil flash[:new_api_token]
  end

  test "revoking a token stops it authenticating" do
    token = ApiToken.mint!(user: @user, name: "laptop")

    delete :destroy, params: { id: token.id }

    assert_redirected_to api_tokens_path
    assert token.reload.revoked?
    assert_nil ApiToken.authenticate(token.plaintext)
  end

  test "one user cannot revoke another's token" do
    other = User.create!(hcb_user_id: "usr_2", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    token = ApiToken.mint!(user: other, name: "not yours")

    delete :destroy, params: { id: token.id }

    assert_redirected_to api_tokens_path
    assert_not token.reload.revoked?
  end
end
