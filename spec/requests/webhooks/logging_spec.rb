require "rails_helper"

# DESIGN.md §11: logs carry our own ids and error classes, never phone numbers,
# Meta message ids (they embed phone numbers), names or message bodies.
RSpec.describe "Webhook logging", type: :request do
  before { create_menu }

  def run_flow(body)
    capture_log do
      post_webhook(body)
      perform_enqueued_jobs(only: ProcessWebhookDeliveryJob)
    end
  end

  # Request ids and job ids are random UUIDs; a hex segment can be all digits
  # (e.g. "596608973083"), which is not a phone number. Strip them first.
  def expect_clean(log)
    log = log.gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "<uuid>")
    expect(log).not_to match(/\d{10,}/), "a long digit run (phone number or id) was logged"
    expect(log).not_to include("wamid.")
    expect(log).not_to include("Test Customer")
    expect(log).not_to include("US.1000000000000002")
  end

  it "logs no phone numbers or Meta ids across the real order flow" do
    log = run_flow(meta_fixture("order"))

    expect(log).to include("event=webhook.stored", "event=webhook.processed", "event=webhook.item")
    expect_clean(log)
  end

  it "stays clean for greetings, statuses, duplicates and failures" do
    create_outbound(status: :accepted, wa_message_id: fixture_wa_id("status_sent"), accepted_at: Time.utc(2026, 8, 8))
    allow(Orders::Builder).to receive(:new).and_raise(RuntimeError, "boom 15550100004")

    log = [ "text_greeting", "status_sent", "status_sent", "order", "status_duplicate_delivery_a" ].map { |name| run_flow(meta_fixture(name)) }.join

    expect(log).to include("event=webhook.item_failed")
    expect_clean(log)
  end

  it "stays clean when the signature is rejected or storage fails" do
    allow(WebhookDelivery).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "INSERT ... 15550100004")

    log = capture_log do
      post_webhook(meta_fixture("order"), signature: "sha256=bogus")
      post_webhook(meta_fixture("order"))
    end

    expect(log).to include("event=webhook.rejected", "event=webhook.ingest_failed")
    expect_clean(log)
  end

  it "does not log SQL bind values for WhatsApp columns" do
    log = run_flow(meta_fixture("order"))

    expect(log).to include("INSERT INTO")
    expect_clean(log)
  end
end
