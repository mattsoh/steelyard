Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Web app manifest (app/views/pwa/manifest.json.erb). Linked from
  # shared/_favicons; it is where Android/Chrome find the home-screen icons.
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  root "home#index"

  get    "login",             to: "sessions#new",      as: :login
  get    "auth/hcb/callback", to: "sessions#callback",  as: :hcb_callback
  delete "logout",            to: "sessions#destroy",   as: :logout

  resources :organizations, only: [ :index ]
  resources :api_tokens, only: [ :index, :create, :destroy ]

  # The programmatic surfaces, both authenticated with the tokens minted above
  # rather than a session: MCP for AI assistants, /api/v1 for everything else.
  # Distinct from the /organizations/:id/api routes below, which exist for this
  # app's own frontend and answer to its session cookie.
  post "mcp", to: "mcp#handle"
  match "mcp", to: "mcp#unsupported", via: [ :get, :delete ]

  # OAuth, so an MCP client that can't be handed a token by hand -- a Claude
  # custom connector -- can send each person through HCB login and consent
  # instead, and act as them afterwards. Discovery is served at both the bare
  # well-known path and the one suffixed with the MCP endpoint's path, because
  # clients probe for either.
  get "/.well-known/oauth-protected-resource",     to: "oauth/metadata#protected_resource"
  get "/.well-known/oauth-protected-resource/mcp", to: "oauth/metadata#protected_resource"
  get "/.well-known/oauth-authorization-server",     to: "oauth/metadata#authorization_server"
  get "/.well-known/oauth-authorization-server/mcp", to: "oauth/metadata#authorization_server"
  get "/.well-known/openid-configuration",           to: "oauth/metadata#authorization_server"

  post "oauth/register",  to: "oauth/registrations#create"
  get  "oauth/authorize", to: "oauth/authorizations#new",    as: :oauth_authorize
  post "oauth/authorize", to: "oauth/authorizations#create"
  post "oauth/token",     to: "oauth/tokens#create"

  get "/api", to: redirect("/api/v1")
  get "/api/v1", to: redirect("/api/v1/me")

  namespace :api do
    namespace :v1 do
      get "me", to: "me#show"
      get "organizations", to: "organizations#index"

      # Organizations are addressed by HCB id or slug, so the segment is
      # widened from the default (which stops at a dot) -- a slug is free to
      # contain one.
      scope "organizations/:organization_id", constraints: { organization_id: %r{[^/]+} } do
        get "",                 to: "organizations#show"
        get "transactions",     to: "transactions#index"
        get "transactions/:id", to: "transactions#show", constraints: { id: %r{[^/]+} }
        get "matches",          to: "matches#index"
        post "matches",         to: "matches#create"
        delete "matches/:id",   to: "matches#destroy"
      end
    end
  end

  match "/api/*path", to: "errors#not_found", via: :all

  scope "/organizations/:organization_id", as: :organization do
    get "matcher", to: "matcher#show", as: :matcher
    get "ledger",  to: "ledger#show",  as: :ledger

    # The shareable link to one match. It's the matcher page with that match's
    # detail popup already open over it -- a match is a relationship between
    # transactions, so landing on it with the rest of the organization behind
    # it is the useful thing, and closing the popup leaves you somewhere you
    # can carry on working.
    get "matches/:id", to: "matcher#show", as: :match, constraints: { id: /\d+/ }

    namespace :api do
      get    "transactions",      to: "transactions#index"
      get    "transactions/page", to: "transactions#page"
      post   "transactions/refresh",     to: "transactions#refresh"
      post   "transactions/reload",      to: "transactions#reload"
      get    "transactions/sync_status", to: "transactions#sync_status"
      get    "transactions/:id/comments", to: "comments#index"
      post   "transactions/:id/refresh", to: "transactions#refresh_one"
      get    "matches",           to: "matches#index"
      get    "matches/:id",       to: "matches#show"
      post   "matches",           to: "matches#create"
      patch  "matches/:id",       to: "matches#update"
      delete "matches/:id",       to: "matches#destroy"
      get    "ledger",            to: "ledger#index"
      get    "ledger/page",       to: "ledger#page"
      patch  "cutoff",            to: "cutoffs#update"
    end
  end

  match "/400", to: "errors#bad_request",           via: :all
  match "/404", to: "errors#not_found",              via: :all
  match "/422", to: "errors#unprocessable_entity",   via: :all
  match "/500", to: "errors#internal_server_error",  via: :all
end
