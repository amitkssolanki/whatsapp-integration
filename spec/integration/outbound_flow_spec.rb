require "rails_helper"

# The whole V2 loop on real sanitized payloads and a fake Graph API:
# order webhook -> order + neutral receipt -> send -> accepted -> status
# webhooks (rewritten to the fake message id) -> read. Then the operator
# accepts the order and the confirmation travels the same road.
RSpec.describe "Order to delivered message", type: :integration do
  let!(:menu) { create_menu }
  let(:order_arrived_at) { Time.at(1_786_204_851).utc } # the fixture message's own timestamp
  let(:receipt_wamid) { "wamid.FAKE-RECEIPT-1" }
  let(:accept_wamid) { "wamid.FAKE-ACCEPT-1" }

  before do
    configure_whatsapp
    travel_to(order_arrived_at + 30.seconds)
  end

  # A fixture addressed to the phone number id this app is configured with (the
  # sanitized fixtures carry assorted fake ids, and foreign numbers are ignored).
  def to_our_number(json)
    json.dig("entry", 0, "changes", 0, "value", "metadata")["phone_number_id"] = Rails.application.config.whatsapp.phone_number_id
    json.to_json
  end

  def payload(name, text = meta_fixture(name)) = to_our_number(JSON.parse(text))

  # A status fixture addressed to a message we "sent", at the fixture's own time.
  def status_for(name, wamid)
    json = fixture_json(name)
    json.dig("entry", 0, "changes", 0, "value", "statuses", 0)["id"] = wamid
    to_our_number(json)
  end

  def run_pipeline
    perform_enqueued_jobs(only: SendMessageJob)
  end

  it "takes a real cart to a read receipt, and an operator decision to a second one" do
    # 1. the order webhook
    delivery = deliver_and_process(payload("order"))
    expect(delivery).to be_processed

    order = Order.sole
    receipt = Message.outbound.sole
    expect(order).to have_attributes(status: "received", total_cents: 2500)
    expect(receipt).to have_attributes(status: "pending", purpose: "order_received", order_id: order.id)
    expect(receipt.body).not_to include("$") # neutral: no total before review
    expect(enqueued_send_ids).to eq([ receipt.id ])

    # 2. the send job talks to (fake) Meta
    graph.reply(200, ok_send(receipt_wamid))
    run_pipeline

    expect(graph.requests.sole.json).to include("to" => "15550100004", "type" => "text", "biz_opaque_callback_data" => receipt.id.to_s)
    expect(receipt.reload).to have_attributes(status: "accepted", wa_message_id: receipt_wamid, attempts: 1)

    # 3. Meta's real status sequence, aimed at our message
    %w[status_sent status_delivered status_read].each do |name|
      expect(deliver_and_process(status_for(name, receipt_wamid))).to be_processed
    end

    expect(receipt.reload).to have_attributes(status: "read", sent_at: Time.at(1_786_174_613).utc, delivered_at: Time.at(1_786_174_619).utc, read_at: Time.at(1_786_174_639).utc)
    expect(Message.undelivered).to be_empty

    # 4. the operator accepts: confirmation with the final total, same road
    expect(order.accept!(by: "amit")).to be_ok
    confirmation = Message.outbound.where(purpose: "order_accepted").sole
    expect(confirmation.body).to include("$25.00")

    graph.reply(200, ok_send(accept_wamid))
    run_pipeline

    expect(graph.calls).to eq(2)
    expect(confirmation.reload).to have_attributes(status: "accepted", wa_message_id: accept_wamid)
    expect(order.reload).to be_accepted

    # 5. nothing is left over for the Health page to complain about
    snapshot = Health::Snapshot.new.call
    expect(snapshot[:outbound][:by_status]).to include("read" => 1, "accepted" => 1, "failed" => 0, "unknown" => 0, "blocked" => 0)
    expect(snapshot[:config_banner][:active]).to be(false)
    expect(snapshot[:deliveries][:failed][:count]).to eq(0)
  end

  it "survives a status overtaking the HTTP response and a redelivered order webhook along the way" do
    deliver_and_process(payload("order"))
    receipt = Message.outbound.sole

    graph.reply(200, ok_send(receipt_wamid)) do
      body = JSON.parse(status_for("status_sent", receipt_wamid)).tap do |json|
        json.dig("entry", 0, "changes", 0, "value", "statuses", 0)["biz_opaque_callback_data"] = receipt.id.to_s
      end.to_json
      deliver_and_process(body)
    end
    deliver_and_process(payload("order").sub("{", "{ ")) # Meta redelivers the order meanwhile
    run_pipeline

    expect(receipt.reload).to have_attributes(status: "sent", wa_message_id: receipt_wamid)
    expect([ Order.count, Message.outbound.count, graph.calls ]).to eq([ 1, 1, 1 ])
  end

  it "blocks the receipt, without calling Meta, when the order was processed after the window closed, and requeues once the customer writes again" do
    deliver_and_process(payload("order"))
    receipt = Message.outbound.sole

    travel_to(order_arrived_at + 25.hours)
    run_pipeline

    expect(graph.calls).to eq(0)
    expect(receipt.reload).to be_blocked
    expect(receipt.requeue!(by: "amit")).to be_refused

    deliver_and_process(payload("text_greeting", meta_fixture("text_greeting").sub("1786173626", (order_arrived_at + 25.hours).to_i.to_s).sub("wamid.", "wamid.AGAIN")))
    graph.reply(200, ok_send("wamid.FAKE-GREETING")).reply(200, ok_send(receipt_wamid)) # the greeting's reply, then the requeued receipt
    expect(receipt.reload.requeue!(by: "amit")).to be_ok
    run_pipeline

    expect(receipt.reload).to be_accepted
    expect(graph.calls).to eq(2)
  end
end
