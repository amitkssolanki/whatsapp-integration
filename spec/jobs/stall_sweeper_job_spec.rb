require "rails_helper"

RSpec.describe StallSweeperJob, type: :job do
  describe "deliveries" do
    it "fails deliveries that have been processing for more than 10 minutes" do
      stalled = create_delivery(status: :processing, last_attempted_at: 11.minutes.ago)
      never_attempted = create_delivery(status: :processing, received_at: 12.minutes.ago)

      described_class.perform_now

      expect(stalled.reload).to have_attributes(status: "failed", last_error_class: "Stalled", last_error_message: "stalled")
      expect(stalled.processed_at).to be_present
      expect(never_attempted.reload).to be_failed
      expect(stalled).to be_replayable
    end

    it "leaves recent processing deliveries and every other status alone" do
      recent = create_delivery(status: :processing, last_attempted_at: 2.minutes.ago)
      others = (WebhookDelivery.statuses.keys - [ "processing" ]).map { |s| create_delivery(status: s, received_at: 1.day.ago, last_attempted_at: 1.day.ago) }

      described_class.perform_now

      expect(recent.reload).to be_processing
      expect(others.map { |d| d.reload.status }).to eq(WebhookDelivery.statuses.keys - [ "processing" ])
    end
  end

  describe "outbound messages" do
    it "marks sends stuck in `sending` for more than 5 minutes as unknown, never failed or pending" do
      stuck = create_outbound(status: :sending)
      stuck.update_columns(updated_at: 6.minutes.ago)

      described_class.perform_now

      expect(stuck.reload.status).to eq("unknown")
    end

    it "leaves recent sends and every other outbound status alone" do
      recent = create_outbound(status: :sending)
      others = (Message.statuses.keys - [ "sending" ]).map do |status|
        create_outbound(status: status).tap { |m| m.update_columns(updated_at: 1.day.ago) }
      end

      described_class.perform_now

      expect(recent.reload).to be_sending
      expect(others.map { |m| m.reload.status }).to eq(Message.statuses.keys - [ "sending" ])
    end
  end

  it "is scheduled every 5 minutes in production and development" do
    recurring = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)

    %w[production development].each do |env|
      expect(recurring.dig(env, "stall_sweeper")).to eq("class" => "StallSweeperJob", "schedule" => "every 5 minutes")
    end
  end
end
