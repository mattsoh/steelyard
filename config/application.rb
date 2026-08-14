require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Steelyard
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks middleware])

    # Middleware is required rather than autoloaded (the stack holds the class
    # itself, so a reloadable copy of it would go stale) and appended last, so
    # it wraps the app more closely than the error-page renderer does -- see
    # the class for why that matters.
    require_relative "../lib/middleware/malformed_json_response"
    config.middleware.use Middleware::MalformedJsonResponse

    # Render our own branded pages for 404/422/400/500 instead of the static
    # files in public/, while still falling back to those files if the app
    # itself is unable to boot.
    config.exceptions_app = self.routes

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
