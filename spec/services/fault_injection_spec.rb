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

      it "ignores the FAULT_INJECT environment variable altogether (the boot check refuses it)" do
        toggles = env(fault_inject: "send:5xx", fault_injection_allowed: "1")

        expect(described_class.requested(toggles)).to eq([])
        expect(described_class.active(toggles)).to eq([])
      end

      it "does nothing without FAULT_INJECTION_ALLOWED=1, and reports the stored toggle as ignored" do
        OpsSetting.current.update!(fault_inject: [ "send:5xx" ])

        expect(described_class.active(env)).to eq([])
        expect(described_class.ignored(env)).to eq([ "send:5xx" ])
      end

      it "honours stored toggles with FAULT_INJECTION_ALLOWED=1 only (not any truthy value)" do
        OpsSetting.current.update!(fault_inject: [ "send:5xx" ])

        expect(described_class.active(env(fault_injection_allowed: "1"))).to eq([ "send:5xx" ])
        expect(described_class.active(env(fault_injection_allowed: "true"))).to eq([])
      end

      it "refuses to switch a toggle on when not allowed" do
        expect { described_class.set!([ "send:5xx" ], by: "amit", env: env) }.to raise_error(FaultInjection::NotAllowed)
        expect(OpsSetting.current.fault_inject).to eq([])
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

  describe "the stored toggles (the runtime switch)" do
    it "are read on every check, so switching off needs no restart" do
      described_class.set!(%w[send:5xx], by: "amit")
      expect(described_class.active?("send:5xx", env)).to be(true)

      described_class.set!([], by: "amit")
      expect(described_class.active?("send:5xx", env)).to be(false)
    end

    it "record who set them and when, and log the change" do
      log = capture_log { described_class.set!(%w[processing:order send:5xx], by: "amit") }

      expect(described_class.stored_state).to include(kinds: %w[processing:order send:5xx], by: "amit")
      expect(described_class.stored_state[:at]).to be_within(5.seconds).of(Time.current)
      expect(log).to include("event=fault.toggled", "by=amit")
    end

    it "add to the FAULT_INJECT environment variable in development and test" do
      described_class.set!(%w[send:5xx], by: "amit")

      expect(described_class.active(env(fault_inject: "processing:order"))).to match_array(%w[processing:order send:5xx])
    end

    it "refuse an unknown kind and a missing operator" do
      expect { described_class.set!(%w[send:explode], by: "amit") }.to raise_error(ArgumentError, /unknown fault kind/)
      expect { described_class.set!(%w[send:5xx], by: "") }.to raise_error(ArgumentError, /by:/)
    end

    it "work on a database that has no ops_settings row yet" do
      OpsSetting.delete_all

      expect(described_class.active(env)).to eq([])
      described_class.set!(%w[send:5xx], by: "amit")
      expect(OpsSetting.count).to eq(1)
    end
  end
end
