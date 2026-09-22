require "test_helper"

# The handoff beacon a closing page sends, exercised through the real middleware
# stack with forgery protection on.
#
# It cannot go through ActionController::TestCase like the rest of the endpoint's
# tests: the thing worth proving here is that a request which physically cannot
# set a header still verifies. sendBeacon has no headers API, so the
# X-CSRF-Token the rest of this app sends (hcb_csrf_shim.js) isn't available to
# it, and the token rides in the form body instead. That path only exists in the
# real request cycle -- the controller tests run with forgery protection off and
# would pass either way.
class StreamHandoffTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b",
                         token_expires_at: 1.hour.from_now)
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @previous_forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  def teardown
    ActionController::Base.allow_forgery_protection = @previous_forgery
    Rails.cache = @previous_cache
  end

  test "a beacon carrying its CSRF token in the form body is accepted" do
    transactions = (1..250).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions)

    Hcb::Client.stub :new, client do
      stub_membership("reader") do
        sign_in_via_hcb!(@user)

        # A cold walk, mid-flight, driven by a browser that is about to close.
        get "/organizations/org_1/api/transactions/page", params: { stream_id: "s1" }
        assert_response :success
        assert JSON.parse(response.body)["has_more"]

        # Exactly what navigator.sendBeacon puts on the wire: form-encoded, no
        # headers of its own.
        post "/organizations/org_1/api/transactions/handoff",
          params: { stream_id: "s1", authenticity_token: page_csrf_token },
          headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

        assert_response :accepted
      end
    end

    # And the walk really is available to be taken over now, rather than in
    # ninety seconds' time.
    assert_equal :resumed, Hcb::OrganizationTransactions.new(client, "org_1").resume_stream!("s1")
    assert_equal transactions.map { |t| t["id"] }, Hcb::OrganizationTransactions.new(client, "org_1").all.map { |t| t["id"] }
  end

  test "a beacon with no token at all is rejected rather than quietly accepted" do
    Hcb::Client.stub :new, FakeHcbClient.new(transactions: []) do
      stub_membership("reader") do
        sign_in_via_hcb!(@user)

        post "/organizations/org_1/api/transactions/handoff",
          params: { stream_id: "s1" },
          headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

        # Forgery protection turns the missing token into an unprocessable
        # entity rather than letting it through -- this endpoint is not special
        # -cased out of it, which is the point of putting the token in the body.
        assert_response :unprocessable_entity
      end
    end
  end

  private

  # The token the layout would have rendered into <meta name="csrf-token">,
  # which is where streaming.js reads it from.
  def page_csrf_token
    get "/organizations/org_1/matcher"
    assert_response :success
    css_select("meta[name=csrf-token]").first["content"]
  end
end
