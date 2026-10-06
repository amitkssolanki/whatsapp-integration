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

  it "writes warnings at warn level, in the same format" do
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.formatter = proc { |severity, _time, _progname, message| "#{severity} #{message}\n" }
    Rails.logger.broadcast_to(logger)
    described_class.warn("window.override_send", message_id: 5, by: "amit")
    Rails.logger.stop_broadcasting_to(logger)

    expect(io.string).to include("WARN event=window.override_send message_id=5 by=amit")
  end

  describe ".tagged" do
    it "adds the fields to every event inside the block, nested, and stops afterwards" do
      line = logged do
        described_class.tagged(simulated: true) do
          described_class.event("a")
          described_class.tagged(run: 2) { described_class.warn("b", delivery_id: 1) }
          described_class.event("c", simulated: false)
        end
        described_class.event("d")
      end

      expect(line.lines[0]).to include("event=a simulated=true")
      expect(line.lines[1]).to include("event=b simulated=true run=2 delivery_id=1")
      expect(line.lines[2]).to include("event=c simulated=false")
      expect(line.lines[3]).to include("event=d")
      expect(line.lines[3]).not_to include("simulated")
    end

    it "restores the previous tags even when the block raises" do
      expect { described_class.tagged(simulated: true) { raise "boom" } }.to raise_error("boom")

      expect(described_class.context).to eq({})
    end
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

  describe ".quietly" do
    it "hides SQL debug lines but not info events" do
      log = logged do
        described_class.quietly do
          Customer.where(whatsapp_number: "x").to_a
          described_class.event("inside")
        end
      end

      expect(log).not_to include("SELECT")
      expect(log).to include("event=inside")
    end
  end
end
