require "test_helper"

class Api::CommentsControllerTest < ActionController::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    session[:user_id] = @user.id
  end

  test "flattens HCB's comments into the shape the detail modal renders" do
    fake_client = FakeHcbClient.new(comments: {
      "txn_1" => [ {
        "id" => "cmt_1",
        "user" => { "name" => "Matthew S" },
        "content" => "Receipt is in the shared drive",
        "file" => "https://hcb.hackclub.com/blob/receipt.pdf",
        "admin_only" => true,
        "created_at" => "2026-06-01T12:00:00.000Z"
      } ]
    })

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1", id: "txn_1" }
      end
    end

    assert_response :success
    assert_equal [ {
      "user_name" => "Matthew S",
      "content" => "Receipt is in the shared drive",
      "file_url" => "https://hcb.hackclub.com/blob/receipt.pdf",
      "admin_only" => true,
      "created_at" => "2026-06-01T12:00:00.000Z"
    } ], JSON.parse(response.body)["comments"]
  end

  # HCB omits `admin_only` entirely unless it's set, and `file` unless one is
  # attached, so the common comment arrives with neither key.
  test "fills in the keys HCB leaves off a plain comment" do
    fake_client = FakeHcbClient.new(comments: { "txn_1" => [ { "id" => "cmt_1", "content" => "no receipt for this" } ] })

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1", id: "txn_1" }
      end
    end

    assert_response :success
    comment = JSON.parse(response.body)["comments"].sole
    assert_equal "", comment["user_name"]
    assert_nil comment["file_url"]
    assert_equal false, comment["admin_only"]
  end

  test "answers with an empty list for a transaction nobody has commented on" do
    Hcb::Client.stub :new, FakeHcbClient.new do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1", id: "txn_quiet" }
      end
    end

    assert_response :success
    assert_empty JSON.parse(response.body)["comments"]
  end
end
