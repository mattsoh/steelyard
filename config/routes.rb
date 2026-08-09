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

  scope "/organizations/:organization_id", as: :organization do
    get "matcher", to: "matcher#show", as: :matcher
    get "ledger",  to: "ledger#show",  as: :ledger

    namespace :api do
      get    "transactions",      to: "transactions#index"
      get    "transactions/page", to: "transactions#page"
      post   "transactions/refresh",     to: "transactions#refresh"
      get    "transactions/sync_status", to: "transactions#sync_status"
      get    "transactions/:id/comments", to: "comments#index"
      get    "matches",           to: "matches#index"
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
