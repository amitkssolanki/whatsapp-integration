require "rails_helper"

RSpec.describe AppLog do
  def logged(&block) = capture_log(&block)

  it "writes one key=value line per event" do
    line = logged { described_class.event("webhook.stored", delivery_id: 12, status: "received", error_class: nil) }

    expect(line.lines.size).to eq(1)
    expect(line).to include("event=webhook.stored delivery_id=12 status=received")
    expect(line).not_to include("error_class")
  end

  it "quotes values that contain spaces" do
    expect(logged { described_class.event("x", reason: "bad signature") }).to include('reason="bad signature"')
  end

  it "refuses PII-shaped fields outside production" do
    %i[body whatsapp_number wa_message_id display_name from].each do |field|
      expect { described_class.event("x", field => "secret") }.to raise_error(ArgumentError, /must not log/)
    end
  end

  it "drops PII-shaped fields in production instead of raising" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

    line = logged { described_class.event("x", body: "secret", delivery_id: 1) }

    expect(line).to include("delivery_id=1")
    expect(line).not_to include("secret")
  end
end
