require "rails_helper"

RSpec.describe "Replaying a webhook delivery", type: :request do
  let!(:menu) { create_menu }
  let(:order_body) { meta_fixture("order") }

  def outcome_results(delivery) = delivery.outcome["items"].map { |item| item["result"] }

  describe "of a processed delivery" do
    it "is all duplicates: no new rows and no new send jobs" do
      delivery = deliver_and_process(order_body)
      counts = [ Message.count, Order.count, OrderItem.count, Customer.count, Conversation.count ]
      sends_before = enqueued_send_ids.size

      delivery.replay!(by: "operator")
      process_deliveries

      expect(delivery.reload).to be_processed
      expect(outcome_results(delivery)).to eq([ "duplicate" ])
      expect([ Message.count, Order.count, OrderItem.count, Customer.count, Conversation.count ]).to eq(counts)
      expect(enqueued_send_ids.size).to eq(sends_before)
    end

    it "records who replayed it, when, and how often" do
      delivery = deliver_and_process(order_body)

      delivery.replay!(by: "alice")
      process_deliveries
      delivery.reload.replay!(by: "bob")
      process_deliveries

      expect(delivery.reload).to have_attributes(replay_count: 2, last_replayed_by: "bob", attempts: 3, status: "processed")
      expect(delivery.last_replayed_at).to be_within(5.seconds).of(Time.current)
    end

    it "moves to processing, enqueues a replay job and logs a webhook.replayed event" do
      delivery = deliver_and_process(order_body)

      log = capture_log { delivery.replay!(by: "operator") }

      expect(delivery.reload).to be_processing
      replay_job = enqueued_jobs.reverse.find { |job| job["job_class"] == "ProcessWebhookDeliveryJob" }
      expect(replay_job["arguments"]).to include(delivery.id)
      expect(log).to include("event=webhook.replayed", "delivery_id=#{delivery.id}", "by=operator")
    end
  end

  describe "when the replay job cannot be enqueued" do
    it "raises and leaves the delivery as it was, instead of stranding it in processing" do
      delivery = deliver_and_process(order_body)
      allow(ProcessWebhookDeliveryJob).to receive(:perform_later).and_return(false)

      expect { delivery.replay!(by: "operator") }.to raise_error(ApplicationJob::EnqueueFailed)

      expect(delivery.reload).to be_processed
      expect(delivery.replay_count).to eq(0)
    end
  end

  describe "of a failed or partially failed delivery" do
    it "applies the items that failed once the cause is fixed, leaving applied ones alone" do
      json = fixture_json("text_greeting")
      json.dig("entry", 0, "changes", 0, "value", "messages") << fixture_json("order").dig("entry", 0, "changes", 0, "value", "messages", 0)
      allow(Orders::Builder).to receive(:new).and_raise(RuntimeError, "temporary bug")
      delivery = deliver_and_process(json.to_json)
      expect(delivery).to be_partially_failed

      allow(Orders::Builder).to receive(:new).and_call_original
      delivery.replay!(by: "operator")
      process_deliveries

      expect(outcome_results(delivery.reload)).to eq(%w[duplicate applied])
      expect(delivery).to be_processed
      expect(delivery.last_error_class).to be_nil
      expect([ Message.inbound.count, Message.outbound.count, Order.count ]).to eq([ 2, 2, 1 ])
    end
  end

  describe "of an orphan status" do
    it "applies it once the message it refers to exists" do
      delivery = deliver_and_process(meta_fixture("status_sent"))
      expect(outcome_results(delivery)).to eq([ "orphan" ])

      message = create_outbound(status: :accepted, wa_message_id: fixture_wa_id("status_sent"), accepted_at: Time.utc(2026, 8, 8))
      delivery.replay!(by: "operator")
      process_deliveries

      expect(outcome_results(delivery.reload)).to eq([ "applied" ])
      expect(message.reload).to have_attributes(status: "sent", sent_at: Time.at(1_786_174_613).utc)
    end
  end

  describe "refusals" do
    it "refuses deliveries that are not in a replayable state" do
      %i[received processing ignored unparseable].each do |status|
        delivery = create_delivery(status: status)

        expect { delivery.replay!(by: "operator") }.to raise_error(WebhookDelivery::NotReplayable, /#{status}/)
        expect(delivery.reload.status).to eq(status.to_s)
      end
      expect(enqueued_jobs).to be_empty
    end

    it "refuses a stored body that was tampered with after storage, changing nothing" do
      delivery = deliver_and_process(order_body)
      delivery.update_columns(raw_body: order_body.sub("MAI-006", "XXX-999"))
      jobs_before = enqueued_jobs.size

      log = capture_log do
        expect { delivery.replay!(by: "operator") }.to raise_error(WebhookDelivery::SignatureRefused)
      end

      expect(delivery.reload).to have_attributes(status: "processed", replay_count: 0)
      expect(enqueued_jobs.size).to eq(jobs_before)
      expect(log).to include("event=webhook.replay_refused")
    end

    it "re-verifies against the CURRENT app secret, so a rotated secret refuses old rows" do
      delivery = deliver_and_process(order_body)
      Rails.application.config.whatsapp.app_secret = "rotated-secret"

      expect { delivery.replay!(by: "operator") }.to raise_error(WebhookDelivery::SignatureRefused)
    end

    it "skips signature verification only when unsigned mode is allowed" do
      Rails.application.config.whatsapp.app_secret = nil
      delivery = create_delivery(status: :failed, body: order_body, signature_header: nil)

      expect { delivery.replay!(by: "operator") }.to raise_error(WebhookDelivery::SignatureRefused)

      Rails.application.config.whatsapp.allow_unsigned = true
      expect { delivery.replay!(by: "operator") }.not_to raise_error
      expect(delivery.reload).to be_processing
    end

    it "does not let two replays race: the second finds the delivery already processing" do
      delivery = deliver_and_process(order_body)
      stale = WebhookDelivery.find(delivery.id)

      delivery.replay!(by: "first")

      expect { stale.replay!(by: "second") }.to raise_error(WebhookDelivery::NotReplayable)
      expect(delivery.reload.replay_count).to eq(1)
    end
  end
end
