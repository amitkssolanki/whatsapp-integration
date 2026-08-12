# Keep specs hermetic: never let a real WHATSAPP_TOKEN/PHONE_NUMBER_ID from
# a developer's .env leak into the suite and attempt a real Graph API call.
# WhatsappClient already no-ops when these are blank (see app/services/whatsapp_client.rb).
RSpec.configure do |config|
  config.before do
    Rails.application.config.whatsapp.token = nil
    Rails.application.config.whatsapp.phone_number_id = nil
  end
end
