ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require_relative "support/fake_hcb_client"
require_relative "support/fake_hcb_oauth"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # PaperTrail keeps whodunnit in a RequestStore that its Rack middleware
    # clears per request -- which controller tests never go through. Without
    # this, the lambda ApplicationController installs outlives the test that
    # set it and gets evaluated against a stale controller by whatever runs
    # next in the same process.
    teardown { RequestStore.clear! }

    # Add more helper methods to be used by all tests here...

    # Stubs Hcb::OrganizationMembers.role_for, which now returns a Membership
    # (role + resolved organization id) rather than a bare role string.
    def stub_membership(role, organization_id: "org_1", &block)
      membership = Hcb::OrganizationMembers::Membership.new(organization_id: organization_id, role: role)
      Hcb::OrganizationMembers.stub :role_for, membership, &block
    end
  end
end

# Integration tests can't write the session directly, so signing in means
# walking the app's own HCB login with the OAuth client stubbed out. Worth it
# over a shortcut: what the callback does on the way back -- returning the user
# to a parked request, for one -- is part of what the flows under test depend on.
class ActionDispatch::IntegrationTest
  def sign_in_via_hcb!(user)
    # dotenv supplies this locally; a bare checkout (or CI) has no .env.
    ENV["HCB_OAUTH_REDIRECT_URI"] ||= "http://www.example.com/auth/hcb/callback"

    identity = { "id" => user.hcb_user_id, "email" => user.email, "name" => user.name }
    Hcb.stub(:oauth_client, FakeHcbOauth.new(identity)) do
      get login_path
      get hcb_callback_path, params: { code: "hcb-code", state: session[:oauth_state] }
    end
    user
  end
end
