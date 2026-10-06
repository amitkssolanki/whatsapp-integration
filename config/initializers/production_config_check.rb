# Fail fast: a production boot with missing configuration must not come up "healthy"
# and then drop Meta webhooks or leave the admin UI open. Skipped for
# `assets:precompile` (Docker build), which runs with SECRET_KEY_BASE_DUMMY and no secrets.
module ProductionConfigCheck
  class Error < StandardError; end

  REQUIRED_ENV = %w[
    WHATSAPP_TOKEN
    WHATSAPP_PHONE_NUMBER_ID
    WHATSAPP_VERIFY_TOKEN
    WHATSAPP_APP_SECRET
    ADMIN_USER
    ADMIN_PASSWORD
    APP_HOST
  ].freeze

  def self.call(env = ENV)
    problems = []

    missing = REQUIRED_ENV.select { |name| env[name].to_s.strip.empty? }
    problems << "missing required environment variables: #{missing.join(', ')}" if missing.any?

    unless env["WHATSAPP_ALLOW_UNSIGNED"].to_s.empty?
      problems << "WHATSAPP_ALLOW_UNSIGNED must not be set in production (webhook signatures are mandatory)"
    end

    return if problems.empty?

    raise Error, "Refusing to boot in production: #{problems.join('; ')}. " \
                 "See docs/deploy/RUNBOOK.md (secrets) and .kamal/secrets."
  end

  def self.skip?(env = ENV)
    env["SECRET_KEY_BASE_DUMMY"].to_s.present?
  end
end

ProductionConfigCheck.call if Rails.env.production? && !ProductionConfigCheck.skip?
