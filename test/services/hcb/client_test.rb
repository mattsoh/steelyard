require "test_helper"

class Hcb::ClientTest < ActiveSupport::TestCase
  # Records the request a call would have made instead of answering it, so a
  # test can assert on the path and params rather than on a canned response --
  # the thing that matters here is *which* HCB route gets asked, since a route
  # that doesn't exist falls through to v4's catch-all and 404s.
  class RecordingAccessToken
    attr_reader :requests

    def initialize(body = "[]")
      @body = body
      @requests = []
    end

    def get(path, params: {})
      @requests << [ path, params ]
      Struct.new(:body).new(@body)
    end
  end

  def client_with(token)
    user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    Hcb::Client.new(user).tap { |c| c.define_singleton_method(:access_token) { token } }
  end

  test "comments asks HCB's shallow comments route, with the transaction as a query param" do
    token = RecordingAccessToken.new
    client_with(token).comments("txn_1")

    assert_equal [ [ "/api/v4/comments", { transaction_id: "txn_1" } ] ], token.requests
  end

  test "comments returns the parsed array HCB answers with" do
    token = RecordingAccessToken.new('[{"content":"looks right to me"}]')

    assert_equal [ { "content" => "looks right to me" } ], client_with(token).comments("txn_1")
  end
end
