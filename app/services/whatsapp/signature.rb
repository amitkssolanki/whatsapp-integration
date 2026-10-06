require "openssl"

module Whatsapp
  # X-Hub-Signature-256 verification. Fails closed: with no app secret
  # configured every request is refused, unless WHATSAPP_ALLOW_UNSIGNED=1 in a
  # development or test environment (never honored anywhere else).
  class Signature
    def self.valid?(raw_body, header, config: Rails.application.config.whatsapp)
      return true if unsigned_allowed?(config)

      secret = config.app_secret
      return false if secret.blank? || header.blank?

      expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body.to_s)
      ActiveSupport::SecurityUtils.secure_compare(header.to_s, expected)
    end

    def self.unsigned_allowed?(config = Rails.application.config.whatsapp)
      config.allow_unsigned == true && Rails.env.local?
    end
  end
end
