Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  root to: redirect("/organizations")

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
      get    "matches",           to: "matches#index"
      post   "matches",           to: "matches#create"
      patch  "matches/:id",       to: "matches#update"
      delete "matches/:id",       to: "matches#destroy"
      get    "ledger",            to: "ledger#index"
      get    "ledger/page",       to: "ledger#page"
      patch  "cutoff",            to: "cutoffs#update"
    end
  end
end
