require "rails_helper"

# docs/operating/PROTOCOL.md: injected evidence must never be mistaken for real,
# including after the fields that carried the first label are overwritten.
RSpec.describe "Durable fault-injection labels", type: :request do
  before { create_menu }

  it "keeps the processing:order label on the delivery after the item rolls back and is replayed" do
    inject_faults("processing:order")
    post_webhook(meta_fixture("order"))
    perform_enqueued_jobs(only: ProcessWebhookDeliveryJob)

    delivery = WebhookDelivery.last
    expect(delivery.injected_faults).to eq([ "injected:processing:order" ])
    expect(Order.count).to eq(0)

    ENV.delete("FAULT_INJECT")
    delivery.replay!(by: "operator")
    perform_enqueued_jobs(only: ProcessWebhookDeliveryJob)

    expect(Order.count).to eq(1)
    expect(delivery.reload.injected_faults).to eq([ "injected:processing:order" ])
    expect(delivery.outcome.dig("summary", "applied")).to eq(1)
  end

  it "keeps the send:5xx label on the message after a successful retry clears its error" do
    inject_faults("send:5xx")
    post_webhook(meta_fixture("text_greeting"))
    perform_enqueued_jobs(only: ProcessWebhookDeliveryJob)
    message = Message.outbound.sole
    # The fixture's timestamp is from August; reopen the 24h window for this send.
    message.conversation.update!(last_inbound_at: Time.current)
    configure_whatsapp
    SendMessageJob.perform_now(message.id)

    expect(message.reload).to be_retry_scheduled
    expect(message.injected_faults).to eq([ "injected:send:5xx" ])

    ENV.delete("FAULT_INJECT")
    graph.reply(200, ok_send)
    SendMessageJob.perform_now(message.id)

    expect(message.reload).to be_accepted
    expect(message.error_details).to be_nil
    expect(message.injected_faults).to eq([ "injected:send:5xx" ])
  end
end
