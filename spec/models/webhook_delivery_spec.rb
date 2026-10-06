require "rails_helper"

RSpec.describe WebhookDelivery, type: :model do
  def build_in_status(status) = create_delivery(status: status)

  it_behaves_like "a state machine"

  it "treats unparseable and ignored as terminal" do
    %w[unparseable ignored].each do |status|
      expect(described_class::ALLOWED_TRANSITIONS).not_to have_key(status)
    end
  end

  it "allows processing again from processed only through the explicit transition (operator replay)" do
    expect(build_in_status(:processed).transition!(:processing)).to be(true)
  end

  it "writes extra attributes, including SQL expressions and jsonb, in the same UPDATE" do
    delivery = create_delivery(status: :received)

    delivery.transition!(:processing, attempts: Arel.sql("attempts + 1"), last_attempted_at: Time.current)
    delivery.transition!(:processed, outcome: { "items" => [], "summary" => { "applied" => 1 } })

    expect(delivery.reload).to have_attributes(attempts: 1, status: "processed")
    expect(delivery.outcome).to eq("items" => [], "summary" => { "applied" => 1 })
  end

  describe "#replayable?" do
    it "is true only for failed, partially_failed and processed" do
      replayable = described_class.statuses.keys.select { |s| build_in_status(s).replayable? }

      expect(replayable).to match_array(%w[failed partially_failed processed])
    end
  end

  describe "a purged delivery" do
    let(:delivery) { create_delivery(status: :failed, raw_body: "", purged_at: Time.utc(2026, 12, 2, 9)) }

    it "is not replayable and says why, changing nothing" do
      expect(delivery).to be_purged
      expect(delivery).not_to be_replayable
      expect { delivery.replay!(by: "operator") }
        .to raise_error(WebhookDelivery::NotReplayable, /raw body was purged on 2026-12-02.*no longer be replayed/)
      expect(delivery.reload).to have_attributes(status: "failed", replay_count: 0)
    end
  end

  describe "a synthetic delivery" do
    let(:body) { '{"object":"whatsapp_business_account","entry":[]}' }
    let(:delivery) { create_delivery(status: :failed, body: body, signature_header: sign(body), synthetic: true) }

    it "is not replayable, refuses to replay with reason synthetic, and changes nothing" do
      log = capture_log do
        expect(delivery).not_to be_replayable
        expect { delivery.replay!(by: "operator") }.to raise_error(WebhookDelivery::NotReplayable, /synthetic \(demo\) delivery cannot be replayed/)
      end

      expect(log).to include("event=webhook.replay_refused", "reason=synthetic")
      expect(delivery.reload).to have_attributes(status: "failed", replay_count: 0)
    end

    it "is refused even with a valid stored signature and every other condition met" do
      expect(delivery.stored_signature_valid?).to be(true)
      expect(delivery).to be_failed
      expect { delivery.replay!(by: "operator") }.to raise_error(WebhookDelivery::NotReplayable)
    end

    it "can be replayed only inside an active Demo::Sandbox, against its own run-local secret" do
      Demo::Sandbox.run(meta: Demo::FakeMeta.new, queue: Demo::InlineQueue.new) do
        own = create_delivery(status: :failed, body: body, signature_header: sign(body, Demo::Sandbox::APP_SECRET), synthetic: true)

        expect(own).to be_replayable
        own.replay!(by: "demo-operator")

        expect(own.reload).to have_attributes(status: "processing", replay_count: 1)
      end
      expect(delivery.reload).not_to be_replayable
    end
  end
end
