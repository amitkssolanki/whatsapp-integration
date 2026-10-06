require "rails_helper"

RSpec.describe Message, type: :model do
  def build_in_status(status)
    # Only the guarded failed -> pending edge needs a category; give failed rows a resendable one.
    create_outbound(status: status, error_category: (status.to_s == "failed" ? "account_config" : nil))
  end

  it_behaves_like "a state machine"

  describe "failed -> pending guard" do
    it "is allowed only for categories an operator can fix" do
      allowed, refused = described_class::RESENDABLE_ERROR_CATEGORIES, %w[request_invalid recipient_not_allowed recipient_undeliverable window_closed account_quality rate_limited]

      allowed.each { |category| expect(create_outbound(status: :failed, error_category: category).transition!(:pending)).to be(true), category }
      refused.each { |category| expect(create_outbound(status: :failed, error_category: category).transition!(:pending)).to be(false), category }
      expect(create_outbound(status: :failed, error_category: nil).transition!(:pending)).to be(false)
    end
  end

  describe "#apply_lifecycle!" do
    let(:t0) { Time.utc(2026, 8, 8, 12, 0, 0) }

    def at(offset) = t0 + offset

    it "advances accepted -> sent -> delivered -> read and stamps each step once" do
      message = create_outbound(status: :accepted, accepted_at: at(0))

      expect(message.apply_lifecycle!("sent", at: at(1))).to be(true)
      expect(message.apply_lifecycle!("delivered", at: at(2))).to be(true)
      expect(message.apply_lifecycle!("read", at: at(3))).to be(true)

      expect(message.reload).to have_attributes(status: "read", sent_at: at(1), delivered_at: at(2), read_at: at(3))
    end

    it "reports a repeated event as unchanged and keeps the first timestamp" do
      message = create_outbound(status: :accepted, accepted_at: at(0))
      message.apply_lifecycle!("delivered", at: at(2))

      expect(message.apply_lifecycle!("delivered", at: at(9))).to be(false)
      expect(message.reload.delivered_at).to eq(at(2))
    end

    it "fills a missing earlier timestamp without moving the state backwards" do
      message = create_outbound(status: :accepted, accepted_at: at(0))
      message.apply_lifecycle!("read", at: at(5))

      expect(message.apply_lifecycle!("delivered", at: at(4))).to be(true)
      expect(message.reload).to have_attributes(status: "read", delivered_at: at(4), read_at: at(5))
    end

    it "catches up to the furthest stamped step when a `sending` message settles as unknown" do
      message = create_outbound(status: :sending)
      message.apply_lifecycle!("sent", at: at(1))
      message.apply_lifecycle!("delivered", at: at(2))
      expect(message.reload).to be_sending

      expect(message.transition!(:unknown, error_category: "ambiguous")).to be(true)

      expect(message.reload).to have_attributes(status: "delivered", error_category: "ambiguous")
    end

    it "catches up after accepted too, and stays put when nothing was stamped" do
      stamped = create_outbound(status: :sending)
      stamped.apply_lifecycle!("read", at: at(3))
      stamped.apply_lifecycle!("accepted", at: at(0))
      expect(stamped.reload.status).to eq("read")

      quiet = create_outbound(status: :sending)
      quiet.transition!(:unknown)
      expect(quiet.reload.status).to eq("unknown")
    end

    it "does not catch up when the message leaves `sending` for retry_scheduled or failed" do
      retried = create_outbound(status: :sending)
      retried.apply_lifecycle!("sent", at: at(1))
      expect(retried.transition!(:retry_scheduled)).to be(true)
      expect(retried.reload.status).to eq("retry_scheduled")

      failed = create_outbound(status: :sending)
      failed.apply_lifecycle!("sent", at: at(1))
      failed.transition!(:failed, error_category: "request_invalid")
      expect(failed.reload.status).to eq("failed")
    end

    it "resolves an `unknown` message forward from a status webhook" do
      message = create_outbound(status: :unknown)

      message.apply_lifecycle!("delivered", at: at(2))

      expect(message.reload).to have_attributes(status: "delivered", delivered_at: at(2))
    end

    it "catches a retry_scheduled message up to what Meta reported, and drops the retry bookkeeping" do
      message = create_outbound(status: :retry_scheduled, attempts: 1, next_attempt_at: 1.minute.from_now,
                                error_category: "transient_platform", error_code: 131_000, error_title: "Busy")

      message.apply_lifecycle!("delivered", at: at(2))

      expect(message.reload).to have_attributes(status: "delivered", delivered_at: at(2), next_attempt_at: nil, error_category: nil, error_code: nil, error_title: nil)
    end

    it "does not resurrect failed, blocked or pending messages" do
      %i[failed blocked pending].each do |status|
        message = create_outbound(status: status)

        message.apply_lifecycle!("delivered", at: at(2))

        expect(message.reload.status).to eq(status.to_s)
      end
    end

    # The sender records `accepted` only after the HTTP call returns, so a status
    # webhook can legitimately beat it. Whatever the interleaving, the message
    # must end at the furthest step Meta reported.
    it "ends at read, never regressing, for all 24 orderings of accepted/sent/delivered/read" do
      events = %w[accepted sent delivered read]

      events.permutation.each do |ordering|
        message = create_outbound(status: :sending)
        ranks = []

        ordering.each do |event|
          message.apply_lifecycle!(event, at: at(events.index(event)))
          ranks << described_class::LIFECYCLE.index(message.status).to_i
        end

        expect(message.reload.status).to eq("read"), "ordering #{ordering.inspect} ended at #{message.status}"
        expect(ranks).to eq(ranks.sort), "ordering #{ordering.inspect} regressed: #{ranks.inspect}"
        expect(message).to have_attributes(accepted_at: at(0), sent_at: at(1), delivered_at: at(2), read_at: at(3))
      end
    end

    it "keeps a message in `sending` while only webhooks have spoken, until the sender records accepted" do
      message = create_outbound(status: :sending)

      message.apply_lifecycle!("delivered", at: at(2))
      expect(message.reload.status).to eq("sending")

      message.apply_lifecycle!("accepted", at: at(0))
      expect(message.reload.status).to eq("delivered")
    end
  end

  describe "#apply_failure!" do
    let(:failed_at) { Time.utc(2026, 8, 8, 12, 0, 0) }

    it "fails an accepted or sent message and stores the error and its category" do
      %i[accepted sent unknown].each do |status|
        message = create_outbound(status: status)

        result = message.apply_failure!(at: failed_at, code: 131030, title: "Not allowed", details: "recipient not in allowed list")

        expect(result).to eq(:applied)
        expect(message.reload).to have_attributes(
          status: "failed", failed_at: failed_at, error_code: 131030, error_title: "Not allowed",
          error_details: "recipient not in allowed list", error_category: "recipient_not_allowed"
        )
      end
    end

    it "classifies unknown codes as unclassified" do
      message = create_outbound(status: :accepted)

      message.apply_failure!(at: failed_at, code: 999_999)

      expect(message.reload.error_category).to eq("unclassified")
    end

    it "reports an anomaly, changing nothing, when the message was already delivered or read" do
      %i[delivered read].each do |status|
        message = create_outbound(status: status)

        expect(message.apply_failure!(at: failed_at, code: 131026)).to eq(:anomaly)
        expect(message.reload).to have_attributes(status: status.to_s, failed_at: nil, error_code: nil)
      end
    end

    it "reports a repeat as a duplicate" do
      message = create_outbound(status: :accepted)
      message.apply_failure!(at: failed_at, code: 131026)

      expect(message.apply_failure!(at: failed_at, code: 131026)).to eq(:duplicate)
    end

    it "ignores a failure for a message that was never sent" do
      expect(create_outbound(status: :pending).apply_failure!(at: failed_at)).to eq(:ignored)
    end
  end

  describe ".undelivered" do
    it "finds accepted/sent messages without a delivery receipt after 10 minutes" do
      stuck = create_outbound(status: :accepted, accepted_at: 11.minutes.ago)
      stuck_sent = create_outbound(status: :sent, accepted_at: 11.minutes.ago)
      create_outbound(status: :accepted, accepted_at: 2.minutes.ago)
      create_outbound(status: :delivered, accepted_at: 11.minutes.ago, delivered_at: 10.minutes.ago)

      expect(described_class.undelivered).to match_array([ stuck, stuck_sent ])
    end
  end

  describe "unknown_at" do
    it "is stamped when a message enters unknown, and not by other transitions" do
      message = create_outbound(status: :sending)
      expect(message.transition!(:accepted)).to be(true)
      expect(message.unknown_at).to be_nil

      other = create_outbound(status: :sending)
      freeze_time do
        expect(other.transition!(:unknown, error_category: "ambiguous")).to be(true)
        expect(other.unknown_at).to eq(Time.current)
      end
    end

    it "is not stamped when the transition is refused" do
      message = create_outbound(status: :pending)

      expect(message.transition!(:unknown)).to be(false)
      expect(message.reload.unknown_at).to be_nil
    end
  end
end
