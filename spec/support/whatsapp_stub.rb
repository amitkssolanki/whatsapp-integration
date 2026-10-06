# Keep specs hermetic: never let a real WHATSAPP_TOKEN, app secret or phone
# number id from a developer's .env leak into the suite, and restore whatever
# a spec changed so the order of examples never matters.
RSpec.configure do |config|
  TEST_APP_SECRET = "test-app-secret".freeze
  TEST_VERIFY_TOKEN = "test-verify-token".freeze

  config.around do |example|
    whatsapp = Rails.application.config.whatsapp
    saved = whatsapp.to_h.dup

    whatsapp.token = nil
    whatsapp.phone_number_id = nil
    whatsapp.catalog_id = nil
    whatsapp.api_version = "v26.0"
    whatsapp.app_secret = TEST_APP_SECRET
    whatsapp.verify_token = TEST_VERIFY_TOKEN
    whatsapp.allow_unsigned = false
    whatsapp.admin_user = nil
    whatsapp.admin_password = nil
    whatsapp.mask_pii = false

    example.run
  ensure
    saved.each { |key, value| whatsapp[key] = value }
  end
end
