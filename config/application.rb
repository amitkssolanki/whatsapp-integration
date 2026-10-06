require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module WhatsappIntegration
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks json_log_formatter.rb])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # The webhook guard is middleware, so it has to be loadable while the
    # middleware stack is built, before the reloader would normally be ready.
    # Loading it once (never reloaded) is what Rack expects of middleware.
    config.autoload_once_paths << root.join("app/middleware").to_s

    # Reject oversized or unsigned webhook POSTs before Rails reads the body
    # (see WebhookGuard). It must sit before Rack::MethodOverride, which parses
    # form-encoded POST bodies to look for `_method`.
    initializer "webhook_guard.middleware", before: :build_middleware_stack do |app|
      app.config.middleware.insert_before Rack::MethodOverride, WebhookGuard
    end

    # Single-database Solid Queue (see db/migrate/*_create_solid_queue_tables.rb).
    config.active_job.queue_adapter = :solid_queue
  end
end
