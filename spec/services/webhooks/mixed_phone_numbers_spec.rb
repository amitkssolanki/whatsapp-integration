require "rails_helper"

# One POST can carry changes for several business phone numbers (a WABA with
# more than one number). Ours must be processed, the rest recorded as ignored,
# decided per change rather than from the first metadata.
RSpec.describe "Webhook batches with mixed phone_number_ids", type: :request do
  let(:ours) { "100000000000003" }
  let(:theirs) { "999000000000009" }

  before { Rails.application.config.whatsapp.phone_number_id = ours }

  def greeting_change(phone_number_id:, wamid:, from:)
    change = fixture_json("text_greeting").dig("entry", 0, "changes", 0)
    change["value"]["metadata"]["phone_number_id"] = phone_number_id
    change["value"]["messages"][0].merge!("id" => wamid, "from" => from, "from_user_id" => nil)
    change["value"]["contacts"][0].merge!("wa_id" => from, "user_id" => nil)
    change
  end

  def status_change(phone_number_id:)
    change = fixture_json("status_sent").dig("entry", 0, "changes", 0)
    change["value"]["metadata"]["phone_number_id"] = phone_number_id
    change
  end

  def batch(*changes) = { object: "whatsapp_business_account", entry: [ { id: "1", changes: changes } ] }.to_json

  def results(delivery) = delivery.outcome["items"].map { |item| [ item["kind"], item["result"], item["detail"] ] }

  it "processes our item and ignores the foreign one when the foreign change comes FIRST" do
    body = batch(
      greeting_change(phone_number_id: theirs, wamid: "wamid.FOREIGN", from: "15550109999"),
      greeting_change(phone_number_id: ours, wamid: "wamid.OURS", from: "15550100004")
    )

    delivery = deliver_and_process(body)

    expect(delivery).to have_attributes(status: "processed", phone_number_id: ours)
    expect(results(delivery)).to eq([ [ "message", "ignored", "phone_number_mismatch" ], [ "message", "applied", "reply=greeting" ] ])
    expect(Message.inbound.pluck(:wa_message_id)).to eq([ "wamid.OURS" ])
    expect(Customer.pluck(:whatsapp_number)).to eq([ "15550100004" ])
    expect(Message.outbound.count).to eq(1)
  end

  it "makes the same decisions when ours comes first, and for foreign statuses too" do
    body = batch(
      greeting_change(phone_number_id: ours, wamid: "wamid.OURS", from: "15550100004"),
      greeting_change(phone_number_id: theirs, wamid: "wamid.FOREIGN", from: "15550109999"),
      status_change(phone_number_id: theirs)
    )

    delivery = deliver_and_process(body)

    expect(delivery.status).to eq("processed")
    expect(results(delivery)).to eq([ [ "message", "applied", "reply=greeting" ], [ "message", "ignored", "phone_number_mismatch" ], [ "status", "ignored", "phone_number_mismatch" ] ])
    expect(delivery.outcome["summary"]).to eq("applied" => 1, "ignored" => 2)
    expect(Message.inbound.count).to eq(1)
  end

  it "ignores the whole delivery, without a job, only when every item is foreign" do
    body = batch(
      greeting_change(phone_number_id: theirs, wamid: "wamid.F1", from: "15550109999"),
      status_change(phone_number_id: "888")
    )

    delivery = deliver(body)

    expect(delivery).to have_attributes(status: "ignored", outcome: { "reason" => "phone_number_mismatch" })
    expect(enqueued_jobs).to be_empty
  end

  it "ends `ignored` when the number only became foreign after ingest (configured later)" do
    Rails.application.config.whatsapp.phone_number_id = nil
    delivery = deliver(batch(greeting_change(phone_number_id: theirs, wamid: "wamid.F1", from: "15550109999")))
    Rails.application.config.whatsapp.phone_number_id = ours

    process_deliveries

    expect(delivery.reload).to have_attributes(status: "ignored")
    expect(Message.count).to eq(0)
  end

  it "treats a change without metadata as foreign when a number is configured, and nothing as foreign otherwise" do
    change = greeting_change(phone_number_id: ours, wamid: "wamid.NOMETA", from: "15550100004")
    change["value"].delete("metadata")

    expect(deliver(batch(change))).to be_ignored

    Rails.application.config.whatsapp.phone_number_id = nil
    expect(deliver(batch(change))).to be_received
  end

  it "labels a mixed batch with our number, not whichever came first" do
    delivery = deliver(batch(
      greeting_change(phone_number_id: theirs, wamid: "wamid.F", from: "15550109999"),
      greeting_change(phone_number_id: ours, wamid: "wamid.O", from: "15550100004")
    ))

    expect(delivery.phone_number_id).to eq(ours)
  end
end
