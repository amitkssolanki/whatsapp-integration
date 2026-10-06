require "rails_helper"

# demo:seed_integration data is synthetic: it must never count in the `real`
# numbers, only in `all`, and never as an injected fault of real operation.
RSpec.describe Ops::Report, "and synthetic data" do
  let(:from) { Time.utc(2026, 10, 20) }
  let(:to) { Time.utc(2026, 10, 21) }
  let(:inside) { Time.utc(2026, 10, 20, 10) }
  let(:report) { described_class.new(from: from, to: to).call }

  let(:real_customer) { create_customer(number: "15550100001", name: "Real Person") }
  let(:synthetic_customer) { Customer.create!(whatsapp_number: "15550102001", display_name: "Somebody", synthetic: true).tap(&:create_conversation!) }

  before do
    # real traffic
    create_delivery(status: :processed, received_at: inside, outcome: { "summary" => { "applied" => 1 } })
    create_outbound(customer: real_customer, status: :read, created_at: inside, accepted_at: inside, sent_at: inside + 1, delivered_at: inside + 2, read_at: inside + 5)
    create_order(customer: real_customer, created_at: inside, review_status: :clear)
    Message.insert({ conversation_id: real_customer.conversation.id, direction: 0, status: 0, message_type: "text", wa_message_id: "wamid.REAL-IN", created_at: inside, updated_at: inside })
    # synthetic traffic, in every table the report reads
    create_delivery(status: :failed, received_at: inside, synthetic: true, injected_faults: [ "injected:processing:order" ], outcome: { "summary" => { "error" => 1 } })
    create_delivery(status: :processed, received_at: inside, synthetic: true, outcome: { "summary" => { "applied" => 1 } })
    create_outbound(customer: synthetic_customer, status: :failed, created_at: inside, error_category: "recipient_undeliverable", error_code: 131026, failed_at: inside,
                    injected_faults: [ "injected:send:5xx" ])
    create_outbound(customer: synthetic_customer, status: :read, created_at: inside, accepted_at: inside, sent_at: inside + 1, delivered_at: inside + 100, read_at: inside + 900)
    create_order(customer: synthetic_customer, created_at: inside, review_status: :needs_review, validation_issues: [ { "code" => "price_mismatch" } ])
    Message.insert({ conversation_id: synthetic_customer.conversation.id, direction: 0, status: 0, message_type: "order", wa_message_id: "sim.in.1", created_at: inside, updated_at: inside })
  end

  it "leaves synthetic deliveries out of the real deliveries, and counts them in all" do
    expect(report[:real][:deliveries]).to include(total: 1)
    expect(report[:real][:deliveries][:by_status]).to include("processed" => 1, "failed" => 0)
    expect(report[:all][:deliveries]).to include(total: 3)
  end

  it "leaves a synthetic customer's messages out of the real outbound numbers and latency" do
    expect(report[:real][:outbound]).to include(total: 1)
    expect(report[:real][:outbound][:by_status]).to include("read" => 1, "failed" => 0)
    expect(report[:real][:outbound][:failed_by_error_category]).to eq({})
    expect(report[:all][:outbound]).to include(total: 3)
    expect(report[:real][:latency][:delivered_to_read]).to include(n: 1, median: 3.0)
    expect(report[:all][:latency]).to eq(report[:real][:latency])
  end

  it "leaves a synthetic customer's orders and inbound messages out of the real sections" do
    expect(report[:real][:orders]).to include(total: 1)
    expect(report[:real][:orders][:review]).to include("clear" => 1, "needs_review" => 0)
    expect(report[:real][:orders][:issue_codes]).to eq({})
    expect(report[:all][:orders]).to include(total: 2)
    expect(report[:all][:orders][:issue_codes]).to eq("price_mismatch" => 1)

    expect(report[:real][:inbound]).to include(messages: 1, distinct_customers: 1)
    expect(report[:all][:inbound]).to include(messages: 2, distinct_customers: 2)
  end

  it "does not count synthetic rows as injected faults, nor the old Demo Customer rule's rows" do
    expect(report[:injected]).to eq(deliveries: { total: 0, by_label: {} }, messages: { total: 0, by_label: {} })
  end

  it "keeps the Demo Customer name rule: such customers are out of the real orders and inbound too" do
    demo = create_customer(number: "15550100099", name: "Demo Customer 7")
    create_order(customer: demo, created_at: inside)

    expect(report[:real][:orders]).to include(total: 1)
    expect(report[:all][:orders]).to include(total: 3)
  end

  it "still counts real injected rows" do
    create_delivery(status: :failed, received_at: inside, injected_faults: [ "injected:repost" ])

    expect(report[:injected][:deliveries]).to eq(total: 1, by_label: { "injected:repost" => 1 })
    expect(report[:real][:deliveries]).to include(total: 1)
  end
end
