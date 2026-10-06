require "rails_helper"

RSpec.describe Ops::Report do
  let(:from) { Time.utc(2026, 10, 20) }
  let(:to) { Time.utc(2026, 10, 21) }
  let(:inside) { Time.utc(2026, 10, 20, 10) }
  let(:report) { described_class.new(from: from, to: to).call }

  def delivery_at(time, body:, **attrs)
    create_delivery(body: body, received_at: time, **attrs)
  end

  describe "period" do
    it "describes the window and where the code came from" do
      ENV["GIT_SHA"] = "abc1234"
      period = report[:period]

      expect(period).to include(from: "2026-10-20T00:00:00Z", to: "2026-10-21T00:00:00Z", git_sha: "abc1234")
      expect(period[:generated_at]).to be_present
    ensure
      ENV.delete("GIT_SHA")
    end

    it "falls back to git, then to unknown" do
      ENV.delete("GIT_SHA")
      expect(report[:period][:git_sha]).to match(/\A(\h{4,40}|unknown)\z/)

      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      expect(described_class.new(from: from, to: to).call[:period][:git_sha]).to eq("unknown")
    end

    it "accepts strings and rejects an empty or reversed window" do
      expect(described_class.new(from: "2026-10-20", to: "2026-10-21").from).to eq(from)
      expect { described_class.new(from: to, to: from) }.to raise_error(ArgumentError)
    end
  end

  describe "deliveries" do
    it "reports zeros for an empty period" do
      deliveries = report[:deliveries]

      expect(deliveries[:total]).to eq(0)
      expect(deliveries[:by_status]).to eq(WebhookDelivery.statuses.keys.to_h { |status| [ status, 0 ] })
      expect(deliveries[:exact_duplicate_bodies]).to eq(0)
      expect(deliveries[:item_outcomes]).to eq(%w[applied duplicate orphan anomaly ignored error].to_h { |key| [ key, 0 ] }.merge("other" => 0))
      expect(deliveries[:items_by_kind]).to eq("message" => 0, "status" => 0)
      expect(deliveries[:replays]).to eq(total: 0, deliveries_replayed: 0)
    end

    it "tallies statuses, duplicates, item outcomes and replays inside [from, to)" do
      body_a = '{"object":"a"}'
      delivery_at(from - 1.day, body: body_a, status: :processed)
      delivery_at(inside, body: body_a, status: :processed, replay_count: 2, outcome: {
        "items" => [ { "kind" => "message" }, { "kind" => "message" }, { "kind" => "status" } ],
        "summary" => { "applied" => 2, "duplicate" => 1 }
      })
      delivery_at(inside + 1.hour, body: body_a, status: :failed)
      delivery_at(inside + 2.hours, body: '{"object":"b"}', status: :partially_failed, replay_count: 1, outcome: {
        "items" => [ { "kind" => "status" } ], "summary" => { "applied" => 1, "error" => 1, "weird" => 3 }
      })
      delivery_at(from, body: '{"object":"c"}', status: :ignored, outcome: { "reason" => "no_items", "items" => [], "summary" => {} })
      delivery_at(to, body: '{"object":"d"}')

      deliveries = report[:deliveries]

      expect(deliveries[:total]).to eq(4)
      expect(deliveries[:by_status]).to include("processed" => 1, "failed" => 1, "partially_failed" => 1, "ignored" => 1, "received" => 0)
      expect(deliveries[:exact_duplicate_bodies]).to eq(2)
      expect(deliveries[:item_outcomes]).to include("applied" => 3, "duplicate" => 1, "error" => 1, "orphan" => 0, "other" => 3)
      expect(deliveries[:items_by_kind]).to eq("message" => 2, "status" => 2)
      expect(deliveries[:replays]).to eq(total: 3, deliveries_replayed: 2)
    end
  end

  describe "orders" do
    it "reports zeros for an empty period" do
      expect(report[:orders]).to eq(
        total: 0,
        review: { "clear" => 0, "needs_review" => 0 },
        by_status: { "received" => 0, "accepted" => 0, "rejected" => 0 },
        issue_codes: {},
        decision_minutes: { n: 0, median: nil, min: nil, max: nil }
      )
    end

    it "tallies review, status, issue codes and decision times" do
      customer = create_customer
      create_order(customer: customer, created_at: from - 1.minute)
      create_order(customer: customer, created_at: inside)
      create_order(customer: customer, created_at: inside, status: :accepted, review_status: :needs_review, decided_at: inside + 30.minutes,
                   validation_issues: [ { "code" => "unknown_sku" }, { "code" => "unknown_sku" }, { "code" => "price_changed" } ])
      create_order(customer: customer, created_at: inside, status: :rejected, decided_at: inside + 90.minutes)
      create_order(customer: customer, created_at: inside, status: :accepted, decided_at: inside + 1.hour)
      create_order(customer: customer, created_at: to)

      orders = report[:orders]

      expect(orders[:total]).to eq(4)
      expect(orders[:review]).to eq("clear" => 3, "needs_review" => 1)
      expect(orders[:by_status]).to eq("received" => 1, "accepted" => 2, "rejected" => 1)
      expect(orders[:issue_codes]).to eq("unknown_sku" => 2, "price_changed" => 1)
      expect(orders[:decision_minutes]).to eq(n: 3, median: 60.0, min: 30.0, max: 90.0)
    end
  end
end
