require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # (kamal-proxy terminates TLS and sends X-Forwarded-Proto: https.)
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # kamal-proxy health-checks the container over plain HTTP, so /up must not redirect.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT (Docker collects it; rotation is configured in config/deploy.yml),
  # one JSON object per line. Tags go out as a `tags` array; request_id and job_id
  # are lifted from them (see JsonLogFormatter).
  require_relative "../../lib/json_log_formatter"
  config.log_tags = [ :request_id ]
  config.colorize_logging = false
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT).tap do |logger|
    logger.formatter = JsonLogFormatter.new
  end

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # No cache backend: the app does not depend on one (no Redis, no Solid Cache).
  config.cache_store = :null_store

  # Active Job uses Solid Queue (set in config/application.rb), supervised inside Puma
  # when SOLID_QUEUE_IN_PUMA=1. Action Mailer is not loaded; the app sends no email.

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # DNS rebinding protection: only the public host is accepted. Boot fails without
  # APP_HOST (see config/initializers/production_config_check.rb).
  config.hosts = [ ENV["APP_HOST"] ] if ENV["APP_HOST"].present?

  # The health check is addressed by IP/container name, so skip host authorization for it.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
