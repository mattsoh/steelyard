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

  # Rails' router unescapes a path segment after matching it, so a request for
  # /api/v1/organizations/a%2F..%2F..%2Fadmin/transactions arrives here as the id
  # "a/../../admin". Interpolated raw, and then normalized by the HTTP client,
  # that addresses an HCB endpoint other than the one the method names -- so the
  # caller would be choosing the route, not this class.
  test "an id carrying path separators can't escape the route it's interpolated into" do
    token = RecordingAccessToken.new("{}")
    client_with(token).organization("a/../../admin")

    path, _params = token.requests.sole
    assert_equal "/api/v4/organizations/a%2F..%2F..%2Fadmin", path
  end

  test "the same holds for a transaction id" do
    token = RecordingAccessToken.new("{}")
    client_with(token).transaction("../organizations")

    assert_equal "/api/v4/transactions/..%2Forganizations", token.requests.sole.first
  end

  test "an ordinary id or slug is left readable" do
    token = RecordingAccessToken.new("{}")
    client_with(token).organization("hq-clearinghouse")

    assert_equal "/api/v4/organizations/hq-clearinghouse", token.requests.sole.first
  end

  # The endpoints that report "was it us or HCB?" read this (see
  # StreamedTransactionPages), so it has to count every call -- including the
  # one that hung and then failed, which is the one worth having timed.
  test "stats count every HCB call the client makes" do
    client = client_with(RecordingAccessToken.new)

    assert_equal 0, client.stats[:requests]

    client.comments("txn_1")
    client.transaction("txn_1")

    assert_equal 2, client.stats[:requests]
    assert_operator client.stats[:ms], :>=, 0
  end

  test "a call that raises is still counted" do
    token = Object.new
    token.define_singleton_method(:get) { |*, **| raise "HCB is down" }
    client = client_with(token)

    assert_raises(RuntimeError) { client.transaction("txn_1") }

    assert_equal 1, client.stats[:requests]
  end

  test "stats are a copy, so a caller can't edit the client's own tally" do
    client = client_with(RecordingAccessToken.new)
    client.comments("txn_1")

    client.stats[:requests] = 99

    assert_equal 1, client.stats[:requests]
  end
end
