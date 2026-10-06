require "rails_helper"

RSpec.describe FaultInjection do
  def env(**values) = values.transform_keys { |key| key.to_s.upcase }

  describe ".active" do
    it "is empty when nothing is set" do
      expect(described_class.active(env)).to eq([])
      expect(described_class.active?("send:5xx", env)).to be(false)
    end

    it "reads a comma-separated list, trimming blanks and repeats" do
      expect(described_class.active(env(fault_inject: " processing:order, send:5xx ,,send:5xx"))).to eq(%w[processing:order send:5xx])
    end

    it "ignores unknown names but reports them" do
      toggles = env(fault_inject: "send:5xx,send:explode")

      expect(described_class.active(toggles)).to eq([ "send:5xx" ])
      expect(described_class.ignored(toggles)).to eq([ "send:explode" ])
    end

    it "is honoured in development and test" do
      allow(Rails.env).to receive(:local?).and_return(true)

      expect(described_class.active?("send:5xx", env(fault_inject: "send:5xx"))).to be(true)
    end

    context "in production" do
      before do
        allow(Rails.env).to receive(:local?).and_return(false)
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      it "does nothing without FAULT_INJECTION_ALLOWED=1, and reports the toggle as ignored" do
        toggles = env(fault_inject: "send:5xx")

        expect(described_class.active(toggles)).to eq([])
        expect(described_class.ignored(toggles)).to eq([ "send:5xx" ])
      end

      it "is honoured with FAULT_INJECTION_ALLOWED=1 only (not any truthy value)" do
        expect(described_class.active(env(fault_inject: "send:5xx", fault_injection_allowed: "1"))).to eq([ "send:5xx" ])
        expect(described_class.active(env(fault_inject: "send:5xx", fault_injection_allowed: "true"))).to eq([])
      end
    end

    it "is never honoured outside development, test and production" do
      allow(Rails.env).to receive(:local?).and_return(false)
      allow(Rails.env).to receive(:production?).and_return(false)

      expect(described_class.active(env(fault_inject: "send:5xx", fault_injection_allowed: "1"))).to eq([])
    end
  end

  describe ".fire" do
    it "logs a warning with the kind and returns the label" do
      log = capture_log { expect(described_class.fire("send:5xx", message_id: 7)).to eq("injected:send:5xx") }

      expect(log).to include("event=fault.injected", "kind=send:5xx", "message_id=7")
    end
  end
end
