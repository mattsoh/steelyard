require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
  end

  test "mint! hands back the token once and keeps only its digest" do
    token = ApiToken.mint!(user: @user, name: "laptop")

    assert token.plaintext.start_with?(ApiToken::PREFIX)
    assert_not_equal token.plaintext, token.token_digest
    # Re-read from the database: the plaintext lives on the minting object and
    # nowhere else, which is what makes "shown once" true.
    assert_nil ApiToken.find(token.id).plaintext
  end

  test "an unnamed token still gets a name" do
    assert_equal "API token", ApiToken.mint!(user: @user, name: "  ").name
  end

  test "authenticate accepts an active token and nothing else" do
    token = ApiToken.mint!(user: @user, name: "laptop")

    assert_equal token, ApiToken.authenticate(token.plaintext)
    assert_nil ApiToken.authenticate("sy_not-a-real-token")
    assert_nil ApiToken.authenticate(nil)
    assert_nil ApiToken.authenticate("")

    token.revoke!
    assert_nil ApiToken.authenticate(token.plaintext)
  end

  test "last_used_at is throttled rather than written on every request" do
    token = ApiToken.mint!(user: @user, name: "laptop")

    token.touch_last_used!
    first = token.reload.last_used_at
    assert first.present?

    token.touch_last_used!
    assert_equal first.to_i, token.reload.last_used_at.to_i

    token.update_column(:last_used_at, (ApiToken::LAST_USED_THROTTLE + 1.minute).ago)
    token.touch_last_used!
    assert token.reload.last_used_at > 1.minute.ago
  end
end
