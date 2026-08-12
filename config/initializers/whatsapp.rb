Rails.application.config.whatsapp = ActiveSupport::OrderedOptions.new.tap do |c|
  c.token = ENV["WHATSAPP_TOKEN"]
  c.phone_number_id = ENV["WHATSAPP_PHONE_NUMBER_ID"]
  c.business_account_id = ENV["WHATSAPP_BUSINESS_ACCOUNT_ID"]
  c.verify_token = ENV["WHATSAPP_VERIFY_TOKEN"]
  c.app_secret = ENV["WHATSAPP_APP_SECRET"]
  c.catalog_id = ENV["CATALOG_ID"]
  c.api_version = ENV.fetch("WHATSAPP_API_VERSION", "v21.0")
end
