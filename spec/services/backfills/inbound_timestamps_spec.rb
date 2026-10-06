require "rails_helper"

RSpec.describe Backfills::InboundTimestamps do
  let(:customer) { create_customer }
  let(:conversation) { customer.conversation }
  let(:epoch) { 1_786_204_851 }

  def inbound(payload: {}, wa_timestamp: nil, created_at: Time.utc(2026, 8, 1), conversation: self.conversation)
    Message.create!(conversation: conversation, direction: :inbound, status: :received, message_type: "text",
                    raw_payload: payload, wa_timestamp: wa_timestamp, created_at: created_at)
  end

  describe "message wa_timestamp" do
    it "is taken from the payload's epoch seconds, in UTC" do
      message = inbound(payload: { "timestamp" => epoch.to_s })

      described_class.call

      expect(message.reload.wa_timestamp).to eq(Time.at(epoch).utc)
    end

    it "leaves existing values, other directions, missing and non-numeric timestamps alone" do
      keep = inbound(payload: { "timestamp" => epoch.to_s }, wa_timestamp: Time.utc(2026, 1, 1))
      none = inbound
      junk = [ inbound(payload: { "timestamp" => "yesterday" }), inbound(payload: { "timestamp" => "-5" }), inbound(payload: { "timestamp" => "99999999999999999999" }),
               inbound(payload: { "timestamp" => 12.5 }) ]
      outbound = create_outbound(customer: customer, raw_payload: { "timestamp" => epoch.to_s })

      described_class.call

      expect(keep.reload.wa_timestamp).to eq(Time.utc(2026, 1, 1))
      expect(([ none ] + junk).map { |m| m.reload.wa_timestamp }).to all(be_nil)
      expect(outbound.reload.wa_timestamp).to be_nil
    end

    it "accepts a numeric JSON value too" do
      message = inbound(payload: { "timestamp" => epoch })

      described_class.call

      expect(message.reload.wa_timestamp).to eq(Time.at(epoch).utc)
    end
  end

  describe "conversations.last_inbound_at" do
    it "becomes the newest inbound wa_timestamp when there is none yet" do
      inbound(payload: { "timestamp" => epoch.to_s })
      inbound(payload: { "timestamp" => (epoch - 500).to_s })

      expect(described_class.call).to eq(messages: 2, conversations: 1)

      expect(conversation.reload.last_inbound_at).to eq(Time.at(epoch).utc)
    end

    it "falls back to the newest inbound created_at when no message has a timestamp" do
      inbound(created_at: Time.utc(2026, 8, 1))
      inbound(created_at: Time.utc(2026, 8, 3))
      create_outbound(customer: customer).update_columns(created_at: Time.utc(2026, 9, 1))

      described_class.call

      expect(conversation.reload.last_inbound_at).to eq(Time.utc(2026, 8, 3))
    end

    it "never moves backwards" do
      conversation.update!(last_inbound_at: Time.utc(2027, 1, 1))
      inbound(payload: { "timestamp" => epoch.to_s })

      described_class.call

      expect(conversation.reload.last_inbound_at).to eq(Time.utc(2027, 1, 1))
    end

    it "leaves a conversation without inbound messages untouched" do
      create_outbound(customer: customer)

      expect(described_class.call).to eq(messages: 0, conversations: 0)
      expect(conversation.reload.last_inbound_at).to be_nil
    end

    it "only touches the conversations that have inbound messages" do
      other = create_customer(number: "15550100099").conversation
      inbound(payload: { "timestamp" => epoch.to_s })

      described_class.call

      expect(other.reload.last_inbound_at).to be_nil
    end
  end

  it "is idempotent" do
    inbound(payload: { "timestamp" => epoch.to_s })
    described_class.call

    expect(described_class.call).to eq(messages: 0, conversations: 0)
  end

  describe "the migration" do
    it "runs the backfill on the way up and does nothing on the way down" do
      require Rails.root.join("db/migrate/20261007000022_backfill_inbound_timestamps").to_s
      message = inbound(payload: { "timestamp" => epoch.to_s })
      migration = BackfillInboundTimestamps.new

      expect { migration.suppress_messages { migration.up } }.to change { message.reload.wa_timestamp }.from(nil).to(Time.at(epoch).utc)
      expect { migration.suppress_messages { migration.down } }.not_to change { message.reload.wa_timestamp }
    end
  end
end
