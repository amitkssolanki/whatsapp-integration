require "rails_helper"

RSpec.describe Redact, type: :job do
  it "replaces digit runs of 8 or more, leaving short numbers readable" do
    text = described_class.scrub("Key (whatsapp_number)=(15550100004) exists; order 42, code 131047, +15551234567")

    expect(text).to eq("Key (whatsapp_number)=([#]) exists; order 42, code 131047, +[#]")
  end

  it "replaces Meta message ids" do
    expect(described_class.scrub("no match for wamid.HBgLMTU1NTAxMDA/9laW7V65==A done")).to eq("no match for [wamid] done")
  end

  it "truncates" do
    expect(described_class.scrub("x" * 1000, limit: 50).length).to eq(50)
  end

  it "prefixes an exception with its class" do
    expect(described_class.exception(ArgumentError.new("bad 15550100004"))).to eq("ArgumentError: bad [#]")
  end

  it "tolerates nil" do
    expect(described_class.scrub(nil)).to eq("")
  end

  describe "in webhook error recording" do
    let!(:menu) { create_menu }

    it "keeps phone numbers and Meta ids out of the item outcome and the delivery's error columns" do
      allow_any_instance_of(Orders::Builder).to receive(:call).and_raise(RuntimeError, "boom for 15550100004 wamid.SECRETID")

      delivery = deliver_and_process(meta_fixture("order"))

      expect(delivery).to be_failed
      stored = [ delivery.last_error_message, delivery.last_error_class, delivery.outcome.to_json ].join(" ")
      expect(stored).to include("RuntimeError")
      expect(stored).not_to include("15550100004")
      expect(stored).not_to include("SECRETID")
    end

    it "scrubs the message when the job itself fails" do
      delivery = deliver(meta_fixture("order"))
      allow(Webhooks::DeliveryProcessor).to receive(:new).and_raise(RuntimeError, "crash 15550100004")

      ProcessWebhookDeliveryJob.perform_now(delivery.id)

      expect(delivery.reload).to have_attributes(status: "failed", last_error_class: "RuntimeError", last_error_message: "crash [#]")
    end
  end
end
