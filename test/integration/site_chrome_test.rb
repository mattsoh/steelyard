require "test_helper"

# The home button and the favicon set live in shared partials that both layouts
# render. These guard against one layout drifting away from the other, which is
# exactly how the legacy pages ended up with no way back to the org list.
class SiteChromeTest < ActionDispatch::IntegrationTest
  test "the Tailwind layout renders the home button" do
    get root_path

    assert_response :success
    assert_select "a#site-logo-link[href=?]", root_path do
      assert_select "img#site-logo"
    end
  end

  test "the Tailwind layout renders the icon set" do
    get root_path

    assert_select "link[rel=icon][href='/favicon.ico']"
    assert_select "link[rel=icon][type='image/svg+xml'][media=?]", "(prefers-color-scheme: light)"
    assert_select "link[rel=icon][type='image/svg+xml'][media=?]", "(prefers-color-scheme: dark)"
    assert_select "link[rel='apple-touch-icon'][sizes='180x180']"
    assert_select "link[rel=manifest][href=?]", pwa_manifest_path(format: :json)
    %w[16x16 32x32 48x48 96x96].each do |size|
      assert_select "link[rel=icon][type='image/png'][sizes=?]", size
    end
  end

  test "the root favicon is served for clients that never parse the HTML" do
    get "/favicon.ico"

    assert_response :success
    assert_equal "image/vnd.microsoft.icon", response.media_type
  end

  test "the manifest lists both plain and maskable icons at 192 and 512" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    icons = JSON.parse(response.body).fetch("icons")
    assert_equal [ [ "192x192", "any" ], [ "512x512", "any" ],
                  [ "192x192", "maskable" ], [ "512x512", "maskable" ] ],
                 icons.map { |i| [ i["sizes"], i["purpose"] ] }
  end
end

class LegacySiteChromeTest < ActionController::TestCase
  tests MatcherController

  test "the legacy layout renders the same home button and icon set" do
    user = User.create!(hcb_user_id: "usr_chrome", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    session[:user_id] = user.id

    stub_membership("member") { get :show, params: { organization_id: "org_1" } }

    assert_response :success
    assert_select "a#site-logo-link[href=?]", root_path do
      assert_select "img#site-logo"
    end
    assert_select "link[rel=icon][href='/favicon.ico']"
    assert_select "link[rel='apple-touch-icon'][sizes='180x180']"
    assert_select "link[rel=manifest]"
  end
end
