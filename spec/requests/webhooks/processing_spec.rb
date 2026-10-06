require "rails_helper"

# Real sanitized V1 payloads driven through ingestion and the processing job.
RSpec.describe "Webhook processing", type: :request do
  let!(:menu) { create_menu }
  let(:greeting) { meta_fixture("text_greeting") }
  let(:order_body) { meta_fixture("order") }

  def outcome_results(delivery) = delivery.outcome["items"].map { |item| item["result"] }

  describe "an order message" do
    it "creates the order with three exactly-priced lines and queues a pending receipt" do
      delivery = deliver_and_process(order_body)

      expect(delivery).to have_attributes(status: "processed", attempts: 1, last_error_class: nil)
      expect(delivery.outcome["summary"]).to eq("applied" => 1)

      order = Order.sole
      expect(order.order_items.order(:id).map { |i| [ i.product_retailer_id, i.quantity, i.item_price_cents, i.catalog_price_cents ] })
        .to eq([ [ "MAI-006", 1, 1550, 1550 ], [ "BEV-001", 1, 450, 450 ], [ "DES-003", 1, 500, 500 ] ])
      expect(order).to have_attributes(total_cents: 2500, catalog_id: "100000000000006", status: "received", review_status: "clear")

      inbound = Message.inbound.sole
      expect(order.source_message).to eq(inbound)
      expect(inbound).to have_attributes(status: "received", message_type: "order", wa_message_id: fixture_wa_id("order"), webhook_delivery_id: delivery.id)
      expect(inbound.wa_timestamp).to eq(Time.at(1_786_204_851).utc)

      receipt = Message.outbound.sole
      expect(receipt).to have_attributes(
        status: "pending", purpose: "order_received", idempotency_key: "order:#{order.id}:received",
        order_id: order.id, message_type: "text", conversation_id: inbound.conversation_id
      )
      expect(receipt.body).to include("3 items").and include("##{order.id}")
      expect(receipt.body).not_to include("$")
      expect(receipt.raw_payload).to eq("request" => { "type" => "text", "body" => receipt.body })
      expect(enqueued_send_ids).to eq([ receipt.id ])
    end

    it "upserts the customer and conversation from the contact block" do
      deliver_and_process(order_body)

      customer = Customer.sole
      expect(customer).to have_attributes(whatsapp_number: "15550100004", display_name: "Test Customer 2", wa_user_id: "US.1000000000000002")
      expect(customer.conversation.last_inbound_at).to eq(Time.at(1_786_204_851).utc)
    end

    it "keeps an order with unknown SKUs and flags it for review" do
      Product.where(sku: "BEV-001").destroy_all

      deliver_and_process(order_body)

      expect(Order.sole).to have_attributes(review_status: "needs_review")
      expect(Order.sole.validation_issues.map { |i| i["code"] }).to eq([ "unknown_sku" ])
      expect(Order.sole.order_items.count).to eq(3)
    end

    it "fails the item, keeps the delivery replayable and writes nothing when the order object is missing" do
      body = fixture_json("order").tap { |json| json.dig("entry", 0, "changes", 0, "value", "messages", 0).delete("order") }.to_json

      delivery = deliver_and_process(body)

      expect(delivery).to have_attributes(status: "failed", last_error_class: "Orders::Builder::MissingOrder")
      expect(outcome_results(delivery)).to eq([ "error" ])
      expect([ Message.count, Order.count ]).to eq([ 0, 0 ])
      expect(delivery).to be_replayable
    end
  end

  describe "a text message" do
    it "answers a greeting with a catalog card featuring a signature dish" do
      deliver_and_process(greeting)

      inbound = Message.inbound.sole
      expect(inbound).to have_attributes(message_type: "text", body: "Hi")

      reply = Message.outbound.sole
      expect(reply).to have_attributes(status: "pending", purpose: "greeting", idempotency_key: "greeting:#{inbound.id}", message_type: "interactive")
      expect(reply.raw_payload["request"]).to include("type" => "catalog_message", "thumbnail_product_retailer_id" => "MAI-006", "body" => reply.body)
      expect(enqueued_send_ids).to eq([ reply.id ])
    end

    it "falls back to any in-stock product for the thumbnail, and to plain text with an empty menu" do
      Product.find_by!(sku: "MAI-006").out_of_stock!
      deliver_and_process(greeting)
      expect(Message.outbound.sole.raw_payload.dig("request", "thumbnail_product_retailer_id")).to be_in(%w[BEV-001 DES-003])

      Message.delete_all
      Product.update_all(availability: Product.availabilities[:out_of_stock])
      Customer.destroy_all
      deliver_and_process(greeting.sub("wamid.", "wamid.OTHER").sub('"Hi"', '"hello"'))
      expect(Message.outbound.sole).to have_attributes(message_type: "text", purpose: "greeting")
      expect(Message.outbound.sole.raw_payload.dig("request", "type")).to eq("text")
    end

    it "answers other text with the fallback" do
      body = greeting.sub('"Hi"', '"what time do you close"')

      deliver_and_process(body)

      expect(Message.outbound.sole).to have_attributes(purpose: "reply", idempotency_key: "reply:#{Message.inbound.sole.id}", message_type: "text")
    end

    it "does not mistake words that merely contain a greeting for one" do
      deliver_and_process(greeting.sub('"Hi"', '"this is a question"'))

      expect(Message.outbound.sole.purpose).to eq("reply")
    end

    it "records other message types without replying" do
      body = fixture_json("text_greeting").tap do |json|
        message = json.dig("entry", 0, "changes", 0, "value", "messages", 0)
        message["type"] = "image"
        message.delete("text")
        message["image"] = { "id" => "media-1" }
      end.to_json

      delivery = deliver_and_process(body)

      expect(Message.inbound.sole.message_type).to eq("image")
      expect(Message.outbound.count).to eq(0)
      expect(delivery).to be_processed
      expect(enqueued_send_ids).to be_empty
    end
  end

  describe "idempotency" do
    it "reprocessing the same delivery creates no new rows and enqueues nothing" do
      delivery = deliver_and_process(order_body)
      counts = [ Message.count, Order.count, OrderItem.count, Customer.count ]
      jobs_before = enqueued_jobs.size

      delivery.update_columns(status: WebhookDelivery.statuses[:received])
      ProcessWebhookDeliveryJob.perform_now(delivery.id)

      expect(delivery.reload).to be_processed
      expect(outcome_results(delivery)).to eq([ "duplicate" ])
      expect([ Message.count, Order.count, OrderItem.count, Customer.count ]).to eq(counts)
      expect(enqueued_jobs.size).to eq(jobs_before)
    end

    it "applies the same message once when it arrives in two different deliveries" do
      first = deliver_and_process(order_body)
      second = deliver_and_process(order_body.sub("{", "{ ")) # different bytes, same logical message

      expect(first.body_sha256).not_to eq(second.body_sha256)
      expect(outcome_results(first)).to eq([ "applied" ])
      expect(outcome_results(second)).to eq([ "duplicate" ])
      expect([ Message.inbound.count, Message.outbound.count, Order.count, OrderItem.count ]).to eq([ 1, 1, 1, 3 ])
      expect(enqueued_send_ids.size).to eq(1)
    end

    it "does not run a delivery that is already processed or being processed" do
      delivery = deliver_and_process(greeting)

      expect { ProcessWebhookDeliveryJob.perform_now(delivery.id) }.not_to change { delivery.reload.attributes }
    end
  end

  describe "status webhooks" do
    let(:conversation) { create_customer.conversation }

    def outbound_for(fixture, status: :accepted, **attrs)
      create_outbound(status: status, wa_message_id: fixture_wa_id(fixture), accepted_at: Time.utc(2026, 8, 8), conversation: conversation, customer: conversation.customer, **attrs)
    end

    it "advances an outbound message sent -> delivered -> read from the real status fixtures" do
      message = outbound_for("status_sent")

      %w[status_sent status_delivered status_read].each { |name| expect(deliver_and_process(meta_fixture(name))).to be_processed }

      expect(message.reload).to have_attributes(
        status: "read", sent_at: Time.at(1_786_174_613).utc, delivered_at: Time.at(1_786_174_619).utc, read_at: Time.at(1_786_174_639).utc
      )
    end

    it "ends at read even when the statuses arrive in reverse order" do
      message = outbound_for("status_sent")

      %w[status_read status_delivered status_sent].each { |name| deliver_and_process(meta_fixture(name)) }

      expect(message.reload).to have_attributes(status: "read", sent_at: Time.at(1_786_174_613).utc, delivered_at: Time.at(1_786_174_619).utc)
    end

    it "treats Meta's real duplicate delivery pair as applied once, then duplicate" do
      message = outbound_for("status_duplicate_delivery_a")

      first = deliver_and_process(meta_fixture("status_duplicate_delivery_a"))
      second = deliver_and_process(meta_fixture("status_duplicate_delivery_b"))

      expect(outcome_results(first)).to eq([ "applied" ])
      expect(outcome_results(second)).to eq([ "duplicate" ])
      expect(second).to be_processed
      expect(message.reload).to have_attributes(status: "delivered", delivered_at: Time.at(1_786_209_992).utc)
    end

    it "records a failed status with its error code, title, details and category" do
      message = outbound_for("status_sent")
      error = fixture_json("graph_error_131030").dig("body", "error")
      body = fixture_json("status_sent").tap do |json|
        status = json.dig("entry", 0, "changes", 0, "value", "statuses", 0)
        status["status"] = "failed"
        status["errors"] = [ { "code" => error["code"], "title" => "Recipient not allowed", "message" => error["message"], "error_data" => error["error_data"] } ]
      end.to_json

      delivery = deliver_and_process(body)

      expect(outcome_results(delivery)).to eq([ "applied" ])
      expect(message.reload).to have_attributes(
        status: "failed", error_code: 131_030, error_title: "Recipient not allowed",
        error_category: "recipient_not_allowed", failed_at: Time.at(1_786_174_613).utc
      )
      expect(message.error_details).to start_with("Recipient phone number not in allowed list")
    end

    it "reports failed-after-delivered as an anomaly and leaves the message delivered" do
      message = outbound_for("status_sent", status: :delivered, delivered_at: Time.utc(2026, 8, 8, 0, 0, 5))
      body = fixture_json("status_sent").tap do |json|
        status = json.dig("entry", 0, "changes", 0, "value", "statuses", 0)
        status["status"] = "failed"
        status["errors"] = [ { "code" => 131_026, "title" => "Message undeliverable" } ]
      end.to_json

      delivery = deliver_and_process(body)

      expect(outcome_results(delivery)).to eq([ "anomaly" ])
      expect(delivery).to be_processed
      expect(message.reload).to have_attributes(status: "delivered", failed_at: nil, error_code: nil)
    end

    it "finds a message by the id we asked Meta to echo and then remembers Meta's id" do
      message = create_outbound(status: :sending, conversation: conversation, customer: conversation.customer)
      body = fixture_json("status_sent").tap do |json|
        json.dig("entry", 0, "changes", 0, "value", "statuses", 0)["biz_opaque_callback_data"] = message.id.to_s
      end.to_json

      delivery = deliver_and_process(body)

      expect(outcome_results(delivery)).to eq([ "applied" ])
      expect(message.reload).to have_attributes(wa_message_id: fixture_wa_id("status_sent"), sent_at: Time.at(1_786_174_613).utc)
    end

    it "ignores statuses it does not track, such as deleted" do
      outbound_for("status_sent")
      body = fixture_json("status_sent").tap { |json| json.dig("entry", 0, "changes", 0, "value", "statuses", 0)["status"] = "deleted" }.to_json

      expect(outcome_results(deliver_and_process(body))).to eq([ "ignored" ])
    end

    describe "for a message we do not know" do
      it "records an orphan and still marks the delivery processed" do
        delivery = deliver_and_process(meta_fixture("status_sent"))

        expect(outcome_results(delivery)).to eq([ "orphan" ])
        expect(delivery).to be_processed
      end

      it "does not resurrect a message found by id that was never in our table" do
        expect(Message.count).to eq(0)
        deliver_and_process(meta_fixture("status_delivered"))

        expect(Message.count).to eq(0)
      end
    end
  end

  describe "partial failure" do
    # A greeting followed by a real order, in one delivery.
    def two_item_body
      json = fixture_json("text_greeting")
      order_message = fixture_json("order").dig("entry", 0, "changes", 0, "value", "messages", 0)
      json.dig("entry", 0, "changes", 0, "value", "messages") << order_message
      json.to_json
    end

    before { allow(Orders::Builder).to receive(:new).and_raise(RuntimeError, "temporary bug") }

    it "applies the good item, rolls back only the bad one, and marks the delivery partially_failed" do
      delivery = deliver_and_process(two_item_body)

      expect(delivery).to have_attributes(status: "partially_failed", last_error_class: "RuntimeError")
      expect(outcome_results(delivery)).to eq(%w[applied error])
      expect(delivery.outcome["summary"]).to eq("applied" => 1, "error" => 1)
      expect(Message.inbound.pluck(:body)).to eq([ "Hi" ])
      expect([ Message.outbound.count, Order.count ]).to eq([ 1, 0 ])
      expect(delivery).to be_replayable
    end
  end

  describe "an uninteresting payload" do
    it "marks a delivery with no messages or statuses ignored" do
      body = { object: "whatsapp_business_account", entry: [ { changes: [ { field: "account_update", value: { event: "x" } } ] } ] }.to_json

      delivery = deliver_and_process(body)

      expect(delivery).to be_ignored
      expect(delivery.outcome["reason"]).to eq("no_items")
    end
  end

  describe "failure handling in the job" do
    it "retries infrastructure errors, leaving the delivery failed in between" do
      delivery = deliver(greeting)
      allow_any_instance_of(Webhooks::MessageHandler).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished, "db down")

      ProcessWebhookDeliveryJob.perform_now(delivery.id)

      expect(delivery.reload).to have_attributes(status: "failed", last_error_class: "ActiveRecord::ConnectionNotEstablished", attempts: 1)
      retry_job = enqueued_jobs.find { |job| job["job_class"] == "ProcessWebhookDeliveryJob" && job["executions"] == 1 }
      expect(retry_job).to be_present
    end

    it "recovers when the infrastructure comes back" do
      delivery = deliver(greeting)
      calls = 0
      allow_any_instance_of(Webhooks::MessageHandler).to receive(:call).and_wrap_original do |original|
        calls += 1
        raise ActiveRecord::Deadlocked, "deadlock" if calls == 1

        original.call
      end

      ProcessWebhookDeliveryJob.perform_now(delivery.id)
      perform_enqueued_jobs(only: ProcessWebhookDeliveryJob)

      expect(delivery.reload).to have_attributes(status: "processed", attempts: 2, last_error_class: nil)
      expect(Message.outbound.count).to eq(1)
    end

    it "gives up after three attempts, leaving a replayable failed delivery" do
      delivery = deliver(greeting)
      allow_any_instance_of(Webhooks::MessageHandler).to receive(:call).and_raise(PG::ConnectionBad, "gone")

      expect {
        3.times { perform_enqueued_jobs(only: ProcessWebhookDeliveryJob) }
      }.to raise_error(PG::ConnectionBad)

      expect(delivery.reload).to be_failed
      expect(delivery.attempts).to eq(3)
      expect(delivery).to be_replayable
    end

    it "does not retry code or data errors: the delivery fails with the reason" do
      delivery = deliver(greeting)
      allow(Webhooks::Payload).to receive(:parse).and_raise(NoMethodError, "boom")

      expect { ProcessWebhookDeliveryJob.perform_now(delivery.id) }.not_to raise_error

      expect(delivery.reload).to have_attributes(status: "failed", last_error_class: "NoMethodError", last_error_message: "boom")
      expect(enqueued_jobs.select { |job| job["job_class"] == "ProcessWebhookDeliveryJob" }.size).to eq(1) # the original
    end

    it "does not retry an item's data error either, and does not hide the other items" do
      delivery = deliver(greeting)
      allow(Customer).to receive(:resolve!).and_raise(ActiveRecord::RecordInvalid)

      ProcessWebhookDeliveryJob.perform_now(delivery.id)

      expect(delivery.reload).to be_failed
      expect(delivery.attempts).to eq(1)
      expect(outcome_results(delivery)).to eq([ "error" ])
    end
  end
end
