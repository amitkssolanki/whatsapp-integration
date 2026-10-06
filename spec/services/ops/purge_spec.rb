require "rails_helper"

RSpec.describe Ops::Purge do
  let(:before) { Time.utc(2026, 12, 1) }
  let(:old) { Time.utc(2026, 11, 1) }
  let(:recent) { Time.utc(2026, 12, 5) }
  let(:customer) { create_customer }
  let(:body) { meta_fixture("order") }

  def delivery_at(time, **attrs)
    create_delivery(body: body, received_at: time, raw_body_base64: Base64.strict_encode64(body), signature_header: sign(body), **attrs)
  end

  def message_at(time, status: :delivered, **attrs)
    create_outbound(status: status, customer: customer, created_at: time, **attrs)
  end

  def purge = described_class.new(before: before).call

  it "blanks the body of deliveries received before the date, marks them purged and keeps everything aggregate" do
    old_delivery = delivery_at(old, status: :processed, outcome: { "summary" => { "applied" => 1 }, "items" => [] }, attempts: 2)
    new_delivery = delivery_at(recent)

    freeze_time do
      expect(purge).to include(deliveries: 1)
      expect(old_delivery.reload).to have_attributes(raw_body: "", raw_body_base64: nil, purged_at: Time.current, status: "processed",
                                                    attempts: 2, body_sha256: Digest::SHA256.hexdigest(body))
    end
    expect(old_delivery.outcome["summary"]).to eq("applied" => 1)
    expect(new_delivery.reload).to have_attributes(raw_body: body, purged_at: nil)
    expect(new_delivery.raw_body_base64).to be_present
  end

  it "treats the date as exclusive" do
    delivery_at(before)

    expect(purge).to include(deliveries: 0)
  end

  it "clears message payloads created before the date, inbound and outbound" do
    old_out = message_at(old)
    old_in = Message.create!(conversation: customer.conversation, direction: :inbound, status: :received, message_type: "text",
                             raw_payload: { "text" => { "body" => "secret" } }, created_at: old)
    new_out = message_at(recent)

    expect(purge).to include(messages: 2)

    expect(old_out.reload.raw_payload).to eq({})
    expect(old_in.reload.raw_payload).to eq({})
    expect(new_out.reload.raw_payload).to eq("request" => { "type" => "text", "body" => "hello" })
  end

  it "leaves outbound messages that are still being sent alone and reports them" do
    in_flight = %i[pending sending retry_scheduled].map { |status| message_at(old, status: status) }
    done = message_at(old, status: :failed)

    expect(purge).to include(messages: 1, skipped_in_flight: 3)

    expect(in_flight.map { |m| m.reload.raw_payload["request"] }).to all(be_present)
    expect(done.reload.raw_payload).to eq({})
  end

  it "does not change the rest of a message or touch updated_at" do
    message = message_at(old, status: :read, read_at: old, body: "hello")
    stamp = message.reload.updated_at

    purge

    expect(message.reload).to have_attributes(body: "hello", status: "read", read_at: old, updated_at: stamp)
  end

  it "is idempotent: a second run counts nothing" do
    delivery_at(old)
    message_at(old)

    expect(purge).to include(deliveries: 1, messages: 1)
    expect(purge).to include(deliveries: 0, messages: 0)
  end

  it "previews the same counts without changing anything" do
    old_delivery = delivery_at(old)
    message_at(old)

    expect(described_class.new(before: before).preview).to eq(deliveries: 1, messages: 1, skipped_in_flight: 0)
    expect(old_delivery.reload).to have_attributes(raw_body: body, purged_at: nil)
  end

  it "logs a warning with the counts" do
    delivery_at(old)

    log = capture_log { purge }

    expect(log).to include("event=ops.purge", "deliveries=1", "before=2026-12-01T00:00:00Z")
  end
end
