require "test_helper"

class Hcb::OrganizationMembersTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
  end

  teardown do
    Rails.cache = @previous_cache
  end

  FakeErrorResponse = Struct.new(:status, :body, :parsed, keyword_init: true)

  class RaisingClient
    def initialize(status)
      @status = status
    end

    def organization(_id, expand: [])
      raise OAuth2::Error.new(FakeErrorResponse.new(status: @status, body: '{"error":"not_authorized"}', parsed: { "error" => "not_authorized" }))
    end
  end

  test "role_for treats a 403 not_authorized org lookup as no membership, not an error" do
    membership = Hcb::OrganizationMembers.role_for(client: RaisingClient.new(403), organization_id: "hq", hcb_user_id: "usr_1")

    assert_nil membership.role
    assert_nil membership.organization_id
  end

  test "role_for treats a 404 org lookup as no membership, not an error" do
    membership = Hcb::OrganizationMembers.role_for(client: RaisingClient.new(404), organization_id: "hq", hcb_user_id: "usr_1")

    assert_nil membership.role
  end

  test "role_for re-raises other OAuth2 errors" do
    assert_raises(OAuth2::Error) do
      Hcb::OrganizationMembers.role_for(client: RaisingClient.new(500), organization_id: "hq", hcb_user_id: "usr_1")
    end
  end

  test "role_for returns the member's role from a successful lookup" do
    client = FakeHcbClient.new(members: [ { "id" => "usr_1", "role" => "manager" } ])
    membership = Hcb::OrganizationMembers.role_for(client: client, organization_id: "org_1", hcb_user_id: "usr_1")

    assert_equal "manager", membership.role
    assert_equal "org_1", membership.organization_id
  end
end
