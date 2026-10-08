Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "home#show"

  resources :products, only: [ :index, :show ]

  get "catalog/feed.csv" => "catalog_feeds#show", as: :catalog_feed

  namespace :webhooks do
    # No format: `/webhooks/whatsapp.json` is a 404, not a second spelling of the endpoint.
    get "whatsapp" => "whatsapp#verify", defaults: { format: nil }, format: false
    post "whatsapp" => "whatsapp#receive", defaults: { format: nil }, format: false
  end

  namespace :admin do
    root "health#show"
    get "health" => "health#show", as: :health
    resource :catalog, only: [], controller: "catalog" do
      post :sync_now
      post :reconcile_now
    end
    resources :conversations, only: [ :index, :show ]
    resources :orders, only: [ :index, :show ] do
      member do
        post :accept
        post :reject
      end
    end
    resources :messages, only: [] do
      member do
        post :resend
        post :requeue
        post :override_window
      end
      post :resend_failed, on: :collection
    end
    resources :deliveries, only: [ :index, :show ] do
      post :replay, on: :member
      post :replay_failed, on: :collection
    end
    resources :products, only: [ :index ]
    post "fault_injection" => "fault_injection#update", as: :fault_injection
  end
end
