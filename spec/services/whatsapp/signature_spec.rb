require "rails_helper"

RSpec.describe Whatsapp::Signature do
  let(:body) { '{"object":"whatsapp_business_account"}' }
  let(:config) { Rails.application.config.whatsapp }

  def sign(payload, secret) = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, payload)

  it "accepts the correct HMAC of the raw body" do
    expect(described_class.valid?(body, sign(body, TEST_APP_SECRET))).to be(true)
  end

  it "rejects a wrong, missing, truncated or tampered signature" do
    expect(described_class.valid?(body, sign(body, "other-secret"))).to be(false)
    expect(described_class.valid?(body, nil)).to be(false)
    expect(described_class.valid?(body, "")).to be(false)
    expect(described_class.valid?(body, sign(body, TEST_APP_SECRET)[0, 20])).to be(false)
    expect(described_class.valid?(body + " ", sign(body, TEST_APP_SECRET))).to be(false)
  end

  context "when no app secret is configured" do
    before { config.app_secret = nil }

    it "fails closed" do
      expect(described_class.valid?(body, sign(body, ""))).to be(false)
      expect(described_class.valid?(body, nil)).to be(false)
    end

    it "skips verification only with WHATSAPP_ALLOW_UNSIGNED in development or test" do
      config.allow_unsigned = true

      expect(described_class.valid?(body, nil)).to be(true)
    end

    it "ignores WHATSAPP_ALLOW_UNSIGNED outside development and test" do
      config.allow_unsigned = true
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

      expect(described_class.valid?(body, nil)).to be(false)
      expect(described_class.unsigned_allowed?).to be(false)
    end
  end
end
