require "rails_helper"

RSpec.describe PiiHelper, type: :helper do
  let(:customer) { Customer.resolve!(whatsapp_number: "15550001234", display_name: "Jordan Rivera") }
  let(:username_customer) { Customer.resolve!(wa_user_id: "US.13491208655302741918", display_name: "Sam") }

  context "unmasked" do
    it "shows the number and the name" do
      expect(helper.pii_masked?).to be(false)
      expect(helper.display_phone(customer)).to eq("+15550001234")
      expect(helper.display_name(customer)).to eq("Jordan Rivera")
      expect(helper.display_customer(customer)).to eq("Jordan Rivera · +15550001234")
    end

    it "falls back to the customer id when there is no name" do
      nameless = Customer.resolve!(whatsapp_number: "15550009999")

      expect(helper.display_name(nameless)).to eq("Customer ##{nameless.id}")
    end

    it "shows a username user with a short id when there is no number" do
      expect(helper.display_phone(username_customer)).to eq("username user •••741918")
    end
  end

  context "masked" do
    before { Rails.application.config.whatsapp.mask_pii = true }

    it "keeps only the last four digits and hides the name" do
      expect(helper.pii_masked?).to be(true)
      expect(helper.display_phone(customer)).to eq("+•• ••••• •1234")
      expect(helper.display_name(customer)).to eq("Customer ##{customer.id}")
      expect(helper.display_customer(customer)).not_to match(/Jordan|5550001/)
    end

    it "masks the username user id further" do
      text = helper.display_phone(username_customer)

      expect(text).to eq("username user •••1918")
      expect(text).not_to include("1349120")
      expect(helper.display_name(username_customer)).to eq("Customer ##{username_customer.id}")
    end
  end

  describe "#mask_ref and #scrub_ids" do
    it "shortens a Meta id to its last six characters" do
      expect(helper.mask_ref("wamid.HBgLMTU1NTAwMDEyMzQVAgASGBQzQTAx")).to eq("…QzQTAx")
      expect(helper.mask_ref(nil)).to eq("—")
    end

    it "removes Meta message ids from free text" do
      expect(helper.scrub_ids("failed for wamid.ABC123== today")).to eq("failed for [id] today")
    end
  end
end
