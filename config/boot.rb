ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.

if ENV["SERVER_MODE"] == "Y" and ENV["RAILS_ENV"] == "production"
  require "dotenv"
  # Fill in only what isn't already set (e.g. by Kamal); never touches .env, .env.local, etc.
  Dotenv.load(File.expand_path("../.env.production", __dir__))
end

require "bootsnap/setup" # Speed up boot time by caching expensive operations.
