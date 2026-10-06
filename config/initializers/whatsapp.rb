Rails.application.config.whatsapp = ActiveSupport::OrderedOptions.new.tap do |c|
  c.token = ENV["WHATSAPP_TOKEN"]
  c.phone_number_id = ENV["WHATSAPP_PHONE_NUMBER_ID"]
  c.business_account_id = ENV["WHATSAPP_BUSINESS_ACCOUNT_ID"]
  c.verify_token = ENV["WHATSAPP_VERIFY_TOKEN"]
  c.app_secret = ENV["WHATSAPP_APP_SECRET"]
  c.catalog_id = ENV["CATALOG_ID"]
  c.api_version = ENV.fetch("WHATSAPP_API_VERSION", "v26.0")

  # Skip webhook signature checks. Only ever honored in development and test
  # (Whatsapp::Signature); production ignores it.
  c.allow_unsigned = ENV["WHATSAPP_ALLOW_UNSIGNED"] == "1"

  # HTTP Basic credentials for the operator UI.
  c.admin_user = ENV["ADMIN_USER"]
  c.admin_password = ENV["ADMIN_PASSWORD"]
end
