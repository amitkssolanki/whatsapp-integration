require "rails_helper"

RSpec.describe "config/initializers/whatsapp.rb" do
  around do |example|
    original = Rails.application.config.whatsapp
    saved = ENV["WHATSAPP_DISPLAY_PHONE_NUMBER"]
    example.run
  ensure
    saved.nil? ? ENV.delete("WHATSAPP_DISPLAY_PHONE_NUMBER") : ENV["WHATSAPP_DISPLAY_PHONE_NUMBER"] = saved
    Rails.application.config.whatsapp = original
  end

  def load_with(value)
    value.nil? ? ENV.delete("WHATSAPP_DISPLAY_PHONE_NUMBER") : ENV["WHATSAPP_DISPLAY_PHONE_NUMBER"] = value
    load Rails.root.join("config/initializers/whatsapp.rb")
    Rails.application.config.whatsapp
  end

  it "keeps only the digits of the business number" do
    expect(load_with("+1 555-010 0000").display_phone_number).to eq("15550100000")
  end

  it "is nil when unset or blank" do
    expect(load_with(nil).display_phone_number).to be_nil
    expect(load_with("  ").display_phone_number).to be_nil
  end
end
