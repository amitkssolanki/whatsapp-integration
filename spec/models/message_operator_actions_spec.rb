require "rails_helper"

RSpec.describe Message, "operator actions", type: :model do
  include ActiveJob::TestHelper

  let(:customer) { create_customer }
  let(:conversation) { customer.conversation }

  def failed(category, **attrs)
    create_outbound(status: :failed, customer: customer, error_category: category, error_code: 133010, error_title: "t", error_details: "d",
                    failed_at: Time.current, attempts: 3, **attrs)
  end

  def send_jobs = enqueued_jobs.select { |job| job["job_class"] == "SendMessageJob" }

  describe "#resend!" do
    it "moves a failed message with a resendable category back to pending, wipes the failure and enqueues it" do
      message = failed("auth_config", wa_message_id: "wamid.OLD", accepted_at: 1.hour.ago)

      log = capture_log { expect(message.resend!(by: "amit")).to be_ok }

      expect(message.reload).to have_attributes(
        status: "pending", attempts: 0, error_code: nil, error_category: nil, error_title: nil, error_details: nil,
        failed_at: nil, wa_message_id: nil, accepted_at: nil
      )
      expect(send_jobs.map { |j| j["arguments"] }).to eq([ [ message.id ] ])
      expect(log).to include("event=message.resend").and include("by=amit").and include("previous_category=auth_config")
    end

    it "clears a window override: the resent message is blocked again until the operator re-confirms (review 2 #8)" do
      configure_whatsapp
      open_window(conversation, at: 30.hours.ago)
      message = create_outbound(status: :blocked, customer: customer, error_category: "window_closed", blocked_at: Time.current)
      message.override_window_send!(by: "amit")
      graph.reply(500, { "error" => { "message" => "x", "code" => 190 } }) # auth_config: resendable
      SendMessageJob.perform_now(message.id)
      expect(message.reload).to have_attributes(status: "failed", error_category: "auth_config", guard_override_by: "amit")

      expect(message.resend!(by: "amit")).to be_ok
      expect(message.reload.guard_override_by).to be_nil
      SendMessageJob.perform_now(message.id)

      expect(graph.calls).to eq(1) # the resend was blocked by the guard, not sent
      expect(message.reload).to have_attributes(status: "blocked", error_category: "window_closed")
    end

    it "is allowed for exactly the resendable categories" do
      Message::RESENDABLE_ERROR_CATEGORIES.each { |category| expect(failed(category).resend!(by: "a")).to be_ok, category }

      refused = %w[request_invalid recipient_not_allowed recipient_undeliverable window_closed account_quality rate_limited transient_platform transient_network ambiguous]
      refused.each do |category|
        message = failed(category)
        result = message.resend!(by: "a")
        expect(result).to be_refused, category
        expect(message.reload).to be_failed
      end
    end

    it "refuses every message that is not failed" do
      (Message.statuses.keys - %w[failed received]).each do |status|
        message = create_outbound(status: status, customer: customer)
        expect(message.resend!(by: "a")).to be_refused
        expect(message.reload.status).to eq(status)
      end
    end

    it "is a no-op the second time" do
      message = failed("account_config")
      message.resend!(by: "a")

      expect(message.resend!(by: "a")).to be_refused
      expect(send_jobs.size).to eq(1)
    end

    it "requires a name for the audit trail" do
      expect { failed("auth_config").resend!(by: nil) }.to raise_error(ArgumentError)
    end

    it "rolls back when the job cannot be enqueued" do
      message = failed("auth_config")
      allow(SendMessageJob).to receive(:perform_later).and_return(false)

      expect { message.resend!(by: "a") }.to raise_error(ApplicationJob::EnqueueFailed)
      expect(message.reload).to be_failed
    end
  end

  describe ".resend_failed!" do
    it "resends every failed message of the category and nothing else" do
      a = failed("auth_config")
      b = failed("auth_config")
      other = failed("account_config")
      sent = create_outbound(status: :accepted, customer: customer, error_category: "auth_config")

      result = described_class.resend_failed!(category: "auth_config", by: "amit")

      expect(result).to be_ok
      expect(result.count).to eq(2)
      expect([ a, b ].map { |m| m.reload.status }).to all(eq("pending"))
      expect(other.reload).to be_failed
      expect(sent.reload).to be_accepted
      expect(send_jobs.size).to eq(2)
    end

    it "refuses a category an operator cannot fix" do
      failed("request_invalid")

      expect(described_class.resend_failed!(category: "request_invalid", by: "a")).to be_refused
      expect(send_jobs).to be_empty
    end
  end

  describe "#requeue!" do
    def blocked(**attrs) = create_outbound(status: :blocked, customer: customer, error_category: "window_closed", blocked_at: Time.current, attempts: 1, **attrs)

    it "moves a blocked message to pending and enqueues it while the window is open" do
      open_window(conversation, at: 1.hour.ago)
      message = blocked

      log = capture_log { expect(message.requeue!(by: "amit")).to be_ok }

      expect(message.reload).to have_attributes(status: "pending", blocked_at: nil, error_category: nil, attempts: 0)
      expect(send_jobs.size).to eq(1)
      expect(log).to include("event=message.requeue").and include("by=amit")
    end

    it "refuses, with a reason and no side effects, while the window is closed" do
      open_window(conversation, at: 25.hours.ago)
      message = blocked

      result = message.requeue!(by: "amit")

      expect(result).to be_refused
      expect(result.reason).to match(/window is closed/)
      expect(message.reload).to be_blocked
      expect(send_jobs).to be_empty
    end

    it "refuses at the 23:55 edge and accepts just before it" do
      open_window(conversation, at: Time.utc(2026, 10, 5, 8, 0, 0))
      message = blocked

      travel_to(Time.utc(2026, 10, 6, 7, 55, 0)) { expect(message.requeue!(by: "a")).to be_refused }
      travel_to(Time.utc(2026, 10, 6, 7, 54, 59)) { expect(message.requeue!(by: "a")).to be_ok }
    end

    it "refuses anything that is not blocked" do
      open_window(conversation)
      (Message.statuses.keys - %w[blocked received]).each do |status|
        message = create_outbound(status: status, customer: customer, error_category: (status == "failed" ? "auth_config" : nil))
        expect(message.requeue!(by: "a")).to be_refused
      end
      expect(send_jobs).to be_empty
    end
  end

  describe "#override_window_send!" do
    it "moves a blocked message to pending with the override recorded, and logs loudly" do
      open_window(conversation, at: 30.hours.ago)
      message = create_outbound(status: :blocked, customer: customer, error_category: "window_closed", blocked_at: Time.current)

      log = capture_log { expect(message.override_window_send!(by: "amit")).to be_ok }

      expect(message.reload).to have_attributes(status: "pending", guard_override_by: "amit", blocked_at: nil, error_category: nil)
      expect(send_jobs.size).to eq(1)
      expect(log).to include("window.override_requested").and include("event=message.override_window_send").and include("by=amit")
    end

    it "refuses anything that is not blocked" do
      message = create_outbound(status: :pending, customer: customer)

      expect(message.override_window_send!(by: "amit")).to be_refused
      expect(message.reload.guard_override_by).to be_nil
    end

    it "makes the job send despite the closed window, end to end" do
      configure_whatsapp
      open_window(conversation, at: 30.hours.ago)
      message = create_outbound(customer: customer)
      SendMessageJob.perform_now(message.id)
      expect(message.reload).to be_blocked
      expect(graph.calls).to eq(0)

      message.override_window_send!(by: "amit")
      graph.reply(200, ok_send("wamid.FAKE-OVR"))
      SendMessageJob.perform_now(message.id)

      expect(graph.calls).to eq(1)
      expect(message.reload).to have_attributes(status: "accepted", wa_message_id: "wamid.FAKE-OVR", guard_override_by: "amit")
    end

    it "lets requeue! then work for the same message once the customer writes again" do
      configure_whatsapp
      open_window(conversation, at: 30.hours.ago)
      message = create_outbound(customer: customer)
      SendMessageJob.perform_now(message.id)

      expect(message.reload.requeue!(by: "a")).to be_refused
      open_window(conversation, at: Time.current)
      expect(message.requeue!(by: "a")).to be_ok

      graph.reply(200, ok_send)
      SendMessageJob.perform_now(message.id)
      expect(message.reload).to be_accepted
    end
  end
end
