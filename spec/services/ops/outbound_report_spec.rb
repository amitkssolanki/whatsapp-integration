require "rails_helper"

RSpec.describe Ops::Report, "outbound metrics" do
  let(:from) { Time.utc(2026, 10, 20) }
  let(:to) { Time.utc(2026, 10, 21) }
  let(:t) { Time.utc(2026, 10, 20, 10) }
  let(:customer) { create_customer }
  let(:report) { described_class.new(from: from, to: to).call }

  def outbound(status, **attrs)
    create_outbound(status: status, customer: customer, created_at: t, **attrs)
  end

  def no_stats = { n: 0, median: nil, min: nil, max: nil }

  it "reports zeros for an empty period" do
    expect(report[:outbound]).to eq(
      total: 0, by_purpose: {},
      by_status: Message.statuses.keys.excluding("received").to_h { |status| [ status, 0 ] },
      failed_by_error_category: {}, error_codes: {}, attempts: { total: 0, messages_retried: 0 },
      unknown: { count: 0, with_sent_at: 0, with_delivered_at: 0, with_read_at: 0 },
      unknown_resolved: 0, unknown_unresolved: 0,
      blocked: 0, guard_overrides: 0, injected_faults: 0, undelivered: 0
    )
    expect(report[:latency]).to eq(accepted_to_sent: no_stats, sent_to_delivered: no_stats, delivered_to_read: no_stats, accepted_to_delivered: no_stats)
    expect(report[:status_anomalies]).to eq(read_before_delivered: 0, delivered_without_sent: 0)
    expect(report[:window]).to eq(blocked_window_closed: 0, failures_131047: 0, disagreements: 0)
  end

  context "with a mix of outbound messages" do
    before do
      outbound(:read, purpose: "order_received", attempts: 1, accepted_at: t, sent_at: t + 2, delivered_at: t + 5, read_at: t + 65)
      outbound(:delivered, purpose: "order_received", attempts: 2, accepted_at: t, sent_at: t + 4, delivered_at: t + 10)
      outbound(:failed, purpose: "order_accepted", attempts: 1, error_code: 131_047, error_category: "request_invalid", failed_at: t)
      outbound(:failed, purpose: "order_accepted", attempts: 3, error_code: 190, error_category: "auth_config", failed_at: t)
      outbound(:failed, attempts: 1, failed_at: t)
      outbound(:blocked, purpose: "order_rejected", blocked_at: t, error_category: "window_closed")
      outbound(:failed, purpose: "order_rejected", attempts: 1, error_code: 131_047, error_category: "request_invalid",
                        guard_override_by: "admin", failed_at: t)
      outbound(:unknown, attempts: 1, sent_at: t, delivered_at: t + 20)
      outbound(:accepted, attempts: 1, accepted_at: to - 11.minutes)
      outbound(:sent, attempts: 1, accepted_at: to - 5.minutes, sent_at: to - 4.minutes)
      outbound(:sent, attempts: 1, accepted_at: to - 30.minutes)
      outbound(:read, attempts: 1, accepted_at: t, delivered_at: t + 100, read_at: t + 50)
      create_outbound(status: :pending, customer: customer, created_at: from - 1.day)
      Message.create!(conversation: customer.conversation, direction: :inbound, message_type: "text", status: :received, created_at: t)
    end

    it "counts outbound messages by purpose, status and failure" do
      outbound = report[:outbound]

      expect(outbound[:total]).to eq(12)
      expect(outbound[:by_purpose]).to eq("order_received" => 2, "order_accepted" => 2, "order_rejected" => 2, "none" => 6)
      expect(outbound[:by_status]).to include("read" => 2, "delivered" => 1, "failed" => 4, "blocked" => 1, "unknown" => 1, "accepted" => 1, "sent" => 2, "pending" => 0)
      expect(outbound[:failed_by_error_category]).to eq("request_invalid" => 2, "auth_config" => 1, "uncategorised" => 1)
      expect(outbound[:error_codes]).to eq("131047" => 2, "190" => 1)
      expect(outbound[:attempts]).to eq(total: 14, messages_retried: 2)
      expect(outbound[:unknown]).to eq(count: 1, with_sent_at: 1, with_delivered_at: 1, with_read_at: 0)
      expect(outbound[:blocked]).to eq(1)
      expect(outbound[:guard_overrides]).to eq(1)
      expect(outbound[:undelivered]).to eq(2)
    end

    it "reports no resolved or unresolved unknowns for messages that never entered unknown" do
      expect(report[:outbound]).to include(unknown_resolved: 0, unknown_unresolved: 0)
    end

    it "evaluates undelivered at the end of the period" do
      earlier = described_class.new(from: from, to: to - 15.minutes).call
      expect(earlier[:outbound][:undelivered]).to eq(1)
    end

    it "summarises latency in seconds with medians only" do
      expect(report[:latency]).to eq(
        accepted_to_sent: { n: 3, median: 4.0, min: 2.0, max: 60.0 },
        sent_to_delivered: { n: 3, median: 6.0, min: 3.0, max: 20.0 },
        delivered_to_read: { n: 2, median: 5.0, min: -50.0, max: 60.0 },
        accepted_to_delivered: { n: 3, median: 10.0, min: 5.0, max: 100.0 }
      )
    end

    it "reports what the timestamps show about out-of-order statuses" do
      expect(report[:status_anomalies]).to eq(read_before_delivered: 1, delivered_without_sent: 1)
    end

    it "separates window blocks, Meta's 131047 refusals and disagreements" do
      expect(report[:window]).to eq(blocked_window_closed: 1, failures_131047: 2, disagreements: 1)
    end
  end

  describe "unknown resolution" do
    let(:unknown_at) { t + 10.minutes }

    def was_unknown(status, **attrs) = outbound(status, unknown_at: unknown_at, **attrs)

    it "counts messages that were unknown and are now sent, delivered or read as resolved, and the rest as unresolved" do
      was_unknown(:delivered, accepted_at: t, delivered_at: unknown_at + 1.minute)
      was_unknown(:read, read_at: unknown_at + 2.minutes)
      was_unknown(:sent, sent_at: unknown_at + 30.seconds)
      was_unknown(:unknown)
      was_unknown(:unknown, sent_at: t) # stamped before unknown_at: no later evidence
      was_unknown(:failed, failed_at: unknown_at + 1.minute)
      outbound(:accepted, accepted_at: t) # never unknown

      expect(report[:outbound]).to include(unknown_resolved: 3, unknown_unresolved: 3)
      expect(report[:outbound][:unknown][:count]).to eq(2)
    end

    it "also resolves by a lifecycle timestamp later than unknown_at when the status column lags" do
      was_unknown(:unknown, delivered_at: unknown_at + 1.minute)

      expect(report[:outbound]).to include(unknown_resolved: 1, unknown_unresolved: 0)
    end

    it "only looks at messages created in the period" do
      create_outbound(status: :delivered, customer: customer, created_at: from - 1.day, unknown_at: from - 1.day, delivered_at: from - 1.day + 1.hour)

      expect(report[:outbound]).to include(unknown_resolved: 0, unknown_unresolved: 0)
    end

    it "is rendered in the Markdown summary" do
      was_unknown(:delivered, delivered_at: unknown_at + 1.minute)

      markdown = described_class.new(from: from, to: to).to_markdown
      expect(markdown).to include("| unknown_resolved | 1 |", "| unknown_unresolved | 0 |")
    end
  end
end
