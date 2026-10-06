require "rails_helper"

RSpec.describe Ops::Report, "output" do
  let(:from) { Time.utc(2026, 10, 20) }
  let(:to) { Time.utc(2026, 10, 21) }
  let(:t) { Time.utc(2026, 10, 20, 10) }
  let(:phone) { "15550100777" }
  let(:wamid) { "wamid.HBgLMTU1NTAxMDA3NzcVAgARGBI5QTNDQUZFMDEyMzQ1Njc4" }
  let(:report) { described_class.new(from: from, to: to) }

  # Records full of exactly the identifying data the report must never echo.
  before do
    customer = create_customer(number: phone, name: "Secret Person")
    bsuid = Customer.resolve!(wa_user_id: "US.13491208655302741918", display_name: "Hidden Name")
    body = %({"entry":[{"messages":[{"from":"#{phone}","id":"#{wamid}"}]}]})
    create_delivery(body: body, received_at: t, status: :processed, outcome: {
      "items" => [ { "kind" => "message", "ref" => wamid, "result" => "applied", "detail" => phone } ], "summary" => { "applied" => 1 }
    })
    create_outbound(customer: customer, status: :delivered, purpose: "order_received", body: "Hi Secret Person, your order #{phone}", created_at: t,
                    wa_message_id: wamid, accepted_at: t, sent_at: t + 1, delivered_at: t + 2)
    create_outbound(customer: bsuid, status: :failed, created_at: t, error_code: 131_047, error_title: "Re-engagement #{phone}", error_details: wamid)
    create_order(customer: customer, created_at: t, validation_issues: [ { "code" => "unknown_sku", "sku" => "SKU-#{phone}" } ])
    Message.create!(conversation: bsuid.conversation, direction: :inbound, message_type: "text", status: :received, created_at: t,
                    wa_message_id: "#{wamid}X", body: "my number is #{phone}")
  end

  # Timestamps and UUIDs are ours and not identifying; mask them before looking for long digit runs.
  def masked(json)
    json.gsub(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z/, "TS").gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "UUID")
  end

  it "serializes to JSON without phone numbers, names, Meta ids or bodies" do
    json = JSON.generate(report.call)

    expect(masked(json)).not_to match(/\d{10,}/)
    expect(json).not_to include("wamid.")
    expect(json).not_to include(phone)
    expect(json).not_to include("Secret Person")
    expect(json).not_to include("Hidden Name")
    expect(json).not_to include("US.134")
    expect(json).not_to include("SKU-")
    expect(JSON.parse(json).keys).to eq(%w[period deliveries orders outbound latency status_anomalies window catalog inbound])
  end

  it "renders a Markdown summary without identifying data either" do
    markdown = report.to_markdown

    expect(markdown).to start_with("# Operations report")
    expect(markdown).to include("## Webhook deliveries", "## Orders", "## Outbound messages", "## Latency", "## Catalog", "## Inbound messages")
    expect(markdown).to include("| Metric | Value |", "| replays.deliveries_replayed | 0 |")
    expect(markdown).to include("| total | 1 |")
    expect(markdown).to include("accepted_to_delivered | n=1, median 2.0s, min 2.0s, max 2.0s |")
    expect(markdown).to include("decision_minutes | n=0, median -, min -, max - |")
    expect(masked(markdown)).not_to match(/\d{10,}/)
    expect(markdown).not_to include("wamid.")
    expect(markdown).not_to include("Secret Person")
  end
end
