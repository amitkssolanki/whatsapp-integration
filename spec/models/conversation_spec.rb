require "rails_helper"

RSpec.describe Conversation, type: :model do
  let(:inbound) { Time.utc(2026, 10, 5, 8, 0, 0) }
  let(:conversation) { create_customer.conversation.tap { |c| c.update!(last_inbound_at: inbound) } }

  describe "#window_closes_at" do
    it "is 24 hours after the last customer message, less a 5 minute safety margin" do
      expect(conversation.window_closes_at).to eq(inbound + 23.hours + 55.minutes)
    end

    it "is nil when the customer has never written" do
      expect(create_customer(number: "15550100077").conversation.window_closes_at).to be_nil
    end
  end

  describe "#window_open?" do
    it "is open up to the second before 23:55:00 and closed from then on" do
      expect(conversation.window_open?(at: inbound)).to be(true)
      expect(conversation.window_open?(at: inbound + 23.hours + 54.minutes + 59.seconds)).to be(true)
      expect(conversation.window_open?(at: inbound + 23.hours + 55.minutes)).to be(false)
      expect(conversation.window_open?(at: inbound + 24.hours + 1.second)).to be(false)
    end

    it "uses the current time by default" do
      travel_to(inbound + 1.hour) { expect(conversation).to be_window_open }
      travel_to(inbound + 25.hours) { expect(conversation).not_to be_window_open }
    end

    it "is closed when the customer has never written" do
      expect(create_customer(number: "15550100077").conversation).not_to be_window_open
    end
  end
end
