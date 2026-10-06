require "rails_helper"

# Review 2 #1: the opaque id names a message, not an attempt. After an operator
# resend, statuses of the earlier attempt (replayed, redelivered or just late)
# must not touch the message again.
RSpec.describe "Statuses of an earlier attempt after a resend", type: :integration do
  let(:customer) { create_customer }

  before do
    configure_whatsapp
    open_window(customer.conversation)
  end

  def outcomes(delivery) = delivery.outcome["items"].map { |item| item.slice("result", "detail") }

  def status_body(wamid, status, message, errors: nil, timestamp: Time.current.to_i)
    json = fixture_json("status_sent")
    item = json.dig("entry", 0, "changes", 0, "value", "statuses", 0)
    item.merge!("id" => wamid, "status" => status, "biz_opaque_callback_data" => message.id.to_s, "timestamp" => timestamp.to_s)
    item["errors"] = errors if errors
    json.dig("entry", 0, "changes", 0, "value", "metadata")["phone_number_id"] = Rails.application.config.whatsapp.phone_number_id
    json.to_json
  end

  let(:unclassified) { [ { "code" => 999_999, "title" => "Something new" } ] }

  def send_once(message, wamid)
    graph.reply(200, ok_send(wamid))
    perform_enqueued_jobs(only: SendMessageJob)
    expect(message.reload.wa_message_id).to eq(wamid)
  end

  it "leaves a resent message at the new attempt's state when the old failed status is replayed" do
    message = create_outbound(customer: customer)
    SendMessageJob.perform_later(message.id)
    send_once(message, "wamid.A")

    failed = deliver_and_process(status_body("wamid.A", "failed", message, errors: unclassified))
    expect(message.reload).to have_attributes(status: "failed", error_category: "unclassified")

    expect(message.resend!(by: "amit")).to be_ok
    send_once(message, "wamid.B")
    deliver_and_process(status_body("wamid.B", "delivered", message))
    expect(message.reload).to have_attributes(status: "delivered", wa_message_id: "wamid.B")

    failed.replay!(by: "amit")
    process_deliveries

    expect(outcomes(failed.reload)).to eq([ { "result" => "orphan", "detail" => "stale id after resend" } ])
    expect(message.reload).to have_attributes(status: "delivered", wa_message_id: "wamid.B", failed_at: nil, error_category: nil)
  end

  it "does not stamp the new attempt with late delivered/read statuses of the old one" do
    message = create_outbound(customer: customer)
    SendMessageJob.perform_later(message.id)
    send_once(message, "wamid.A")
    deliver_and_process(status_body("wamid.A", "failed", message, errors: unclassified))
    expect(message.reload.resend!(by: "amit")).to be_ok
    send_once(message, "wamid.B")
    expect(message.reload).to have_attributes(status: "accepted", delivered_at: nil, read_at: nil)

    late = %w[delivered read].map { |status| deliver_and_process(status_body("wamid.A", status, message)) }

    expect(late.flat_map { |delivery| outcomes(delivery) }).to all(include("result" => "orphan", "detail" => "stale id after resend"))
    expect(message.reload).to have_attributes(status: "accepted", wa_message_id: "wamid.B", delivered_at: nil, read_at: nil)
  end

  it "does not assign an old attempt's id to a resent message that is still waiting to be sent" do
    message = create_outbound(customer: customer, status: :failed, error_category: "unclassified", failed_at: Time.current)
    message.resend!(by: "amit")
    expect(message.reload).to be_pending

    delivery = deliver_and_process(status_body("wamid.A", "delivered", message))

    expect(outcomes(delivery)).to eq([ { "result" => "orphan", "detail" => "stale id after resend" } ])
    expect(message.reload).to have_attributes(status: "pending", wa_message_id: nil, delivered_at: nil)
  end

  it "still adopts the opaque id while the first send has not been recorded yet" do
    message = create_outbound(customer: customer, status: :sending)

    delivery = deliver_and_process(status_body("wamid.A", "sent", message))

    expect(outcomes(delivery).sole).to include("result" => "applied")
    expect(message.reload).to have_attributes(wa_message_id: "wamid.A", sent_at: be_present)
  end
end
