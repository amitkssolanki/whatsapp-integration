require "rails_helper"

RSpec.describe Order, "operator decisions", type: :model do
  include ActiveJob::TestHelper

  let(:customer) { create_customer }
  let(:order) do
    create_order(customer: customer, total_cents: 2500).tap do |o|
      o.order_items.create!(product_retailer_id: "MAI-006", quantity: 2, item_price_cents: 1000)
      o.order_items.create!(product_retailer_id: "DES-003", quantity: 1, item_price_cents: 500)
    end
  end

  def notifications = Message.outbound.where(order_id: order.id)

  describe "#accept!" do
    it "accepts, records who and when, and queues one notification stating the final total" do
      result = order.accept!(by: "amit")

      expect(result).to be_ok
      expect(order.reload).to have_attributes(status: "accepted", decided_by: "amit")
      expect(order.decided_at).to be_within(5.seconds).of(Time.current)

      message = notifications.sole
      expect(message).to have_attributes(status: "pending", purpose: "order_accepted", idempotency_key: "order:#{order.id}:accepted", message_type: "text")
      expect(message.body).to include("##{order.id}").and include("3 items").and include("$25.00")
      expect(message.raw_payload).to eq("request" => { "type" => "text", "body" => message.body })
      expect(enqueued_jobs.map { |j| [ j["job_class"], j["arguments"] ] }).to eq([ [ "SendMessageJob", [ message.id ] ] ])
    end

    it "is a no-op the second time (double click): one notification, one job, original decider kept" do
      order.accept!(by: "amit")

      again = order.accept!(by: "someone-else")

      expect(again).to be_refused
      expect(again.reason).to match(/already accepted/)
      expect(notifications.count).to eq(1)
      expect(enqueued_jobs.size).to eq(1)
      expect(order.reload.decided_by).to eq("amit")
    end

    it "is a no-op for a stale in-memory copy" do
      stale = Order.find(order.id)
      order.accept!(by: "amit")

      expect(stale.accept!(by: "bob")).to be_refused
      expect(notifications.count).to eq(1)
    end

    it "cannot accept a rejected order" do
      order.reject!(by: "amit", reason: "out of stock")

      expect(order.accept!(by: "amit")).to be_refused
      expect(order.reload).to be_rejected
      expect(notifications.pluck(:purpose)).to eq([ "order_rejected" ])
    end

    it "queues nothing when the notification cannot be queued: the decision rolls back too" do
      allow(Messages::Outbox).to receive(:queue).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { order.accept!(by: "amit") }.to raise_error(ActiveRecord::StatementInvalid)
      expect(order.reload).to be_received
      expect(order.decided_by).to be_nil
    end

    it "requires a decider" do
      expect { order.accept!(by: "") }.to raise_error(ArgumentError, /by:/)
    end
  end

  describe "#reject!" do
    it "rejects with the reason stored internally and a neutral notification that does not repeat it" do
      result = order.reject!(by: "amit", reason: "  kitchen closed early ")

      expect(result).to be_ok
      expect(order.reload).to have_attributes(status: "rejected", decided_by: "amit", rejection_reason: "kitchen closed early")

      message = notifications.sole
      expect(message).to have_attributes(purpose: "order_rejected", idempotency_key: "order:#{order.id}:rejected")
      expect(message.body).to include("##{order.id}").and include("can't fulfil")
      expect(message.body).not_to include("kitchen")
      expect(enqueued_jobs.size).to eq(1)
    end

    it "requires a reason and changes nothing without one" do
      [ nil, "", "   " ].each do |reason|
        result = order.reject!(by: "amit", reason: reason)
        expect(result).to be_refused
        expect(result.reason).to match(/reason/)
      end
      expect(order.reload).to be_received
      expect(notifications).to be_empty
      expect(enqueued_jobs).to be_empty
    end

    it "is a no-op the second time" do
      order.reject!(by: "amit", reason: "closed")

      expect(order.reject!(by: "amit", reason: "closed")).to be_refused
      expect(notifications.count).to eq(1)
      expect(enqueued_jobs.size).to eq(1)
    end
  end

  it "queues the notification on the customer's conversation, so the 24h guard applies to it later" do
    order.accept!(by: "amit")

    expect(notifications.sole.conversation).to eq(customer.conversation)
  end

  it "never states a total in the automatic receipt, and does in the acceptance" do
    receipt = Conversations::Responder.new.order_received(order: order)
    accepted = Conversations::Responder.new.order_accepted(order: order)

    expect(receipt.body).not_to include("$")
    expect(accepted.body).to include("$25.00")
  end
end
