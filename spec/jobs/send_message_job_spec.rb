require "rails_helper"

RSpec.describe SendMessageJob, type: :job do
  let(:now) { Time.utc(2026, 10, 6, 12, 0, 0) }
  let(:customer) { create_customer }
  let(:conversation) { customer.conversation }

  before do
    configure_whatsapp
    travel_to(now)
    open_window(conversation, at: now - 1.hour)
  end

  def outbound(status: :pending, **attrs) = create_outbound(status: status, customer: customer, **attrs)

  def perform(message) = described_class.perform_now(message.id)

  def retry_jobs = enqueued_jobs.select { |job| job["job_class"] == "SendMessageJob" }

  describe "a successful send" do
    it "claims, sends once, stores Meta's id and ends accepted with a timestamp" do
      message = outbound
      graph.reply(200, ok_send("wamid.FAKE-A"))

      perform(message)

      expect(graph.calls).to eq(1)
      expect(message.reload).to have_attributes(
        status: "accepted", wa_message_id: "wamid.FAKE-A", accepted_at: now, attempts: 1,
        error_code: nil, error_category: nil, next_attempt_at: nil
      )
      expect(retry_jobs).to be_empty
    end

    it "sends the stored request, our message id as the callback data, and the phone number as recipient" do
      message = outbound(message_type: "interactive", raw_payload: { "request" => { "type" => "catalog_message", "body" => "Browse", "thumbnail_product_retailer_id" => "MAI-006" } })
      graph.reply(200, ok_send)

      perform(message)

      expect(graph.requests.sole.json).to include("to" => "15550100004", "type" => "interactive", "biz_opaque_callback_data" => message.id.to_s)
    end

    it "addresses a customer without a phone number by business-scoped user id" do
      phone_less = Customer.resolve!(wa_user_id: "US.77")
      open_window(phone_less.conversation, at: now - 1.hour)
      message = create_outbound(customer: phone_less)
      graph.reply(200, ok_send)

      perform(message)

      expect(graph.requests.sole.json).to include("recipient" => "US.77")
      expect(graph.requests.sole.json).not_to have_key("to")
    end

    it "makes the HTTP call outside any transaction the job opened" do
      message = outbound
      baseline = ActiveRecord::Base.connection.open_transactions
      during = nil
      graph.reply(200, ok_send) { during = ActiveRecord::Base.connection.open_transactions }

      perform(message)

      expect(during).to eq(baseline)
    end

    it "clears the error left by an earlier retryable failure" do
      message = outbound(status: :retry_scheduled, attempts: 1, error_code: 131016, error_category: "transient_platform", error_title: "Busy")
      graph.reply(200, ok_send)

      perform(message)

      expect(message.reload).to have_attributes(status: "accepted", attempts: 2, error_code: nil, error_category: nil, error_title: nil)
    end
  end

  describe "the claim" do
    it "does nothing for rows that are not pending or retry_scheduled, and never calls Meta" do
      (Message.statuses.keys - %w[received pending retry_scheduled]).each do |status|
        message = outbound(status: status)
        expect { perform(message) }.not_to(change { message.reload.attributes })
      end
      expect(graph.calls).to eq(0)
    end

    it "ignores a missing message and an inbound message" do
      inbound = Message.create!(conversation: conversation, direction: :inbound, status: :received, message_type: "text")

      expect { described_class.perform_now(0) }.not_to raise_error
      expect { perform(inbound) }.not_to raise_error
      expect(graph.calls).to eq(0)
    end

    it "makes a second perform a no-op: one message, one HTTP call" do
      message = outbound
      graph.reply(200, ok_send)

      2.times { perform(message) }

      expect(graph.calls).to eq(1)
      expect(message.reload).to have_attributes(status: "accepted", attempts: 1)
    end

    it "sends exactly once when the same job is performed while the first is mid-flight" do
      message = outbound
      graph.reply(200, ok_send) { perform(message) } # a second worker arrives during the first one's HTTP call

      perform(message)

      expect(graph.calls).to eq(1)
      expect(message.reload).to be_accepted
    end
  end

  describe "an early status webhook" do
    def status_body(name, wamid:, opaque:)
      fixture_json(name).tap do |json|
        status = json.dig("entry", 0, "changes", 0, "value", "statuses", 0)
        status["id"] = wamid
        status["biz_opaque_callback_data"] = opaque.to_s
        status["timestamp"] = (now.to_i + 1).to_s
      end.to_json
    end

    it "lands on `sent` when the sent status overtakes the HTTP response" do
      message = outbound
      graph.reply(200, ok_send("wamid.FAKE-EARLY")) do
        deliver_and_process(status_body("status_sent", wamid: "wamid.FAKE-EARLY", opaque: message.id))
      end

      perform(message)

      expect(message.reload).to have_attributes(status: "sent", wa_message_id: "wamid.FAKE-EARLY", accepted_at: now, sent_at: now + 1.second)
    end

    it "lands on `read` when sent, delivered and read all overtake the response" do
      message = outbound
      graph.reply(200, ok_send("wamid.FAKE-EARLY")) do
        %w[status_sent status_delivered status_read].each_with_index do |name, i|
          deliver_and_process(status_body(name, wamid: "wamid.FAKE-EARLY", opaque: message.id).sub(/"timestamp":"\d+"/, "\"timestamp\":\"#{now.to_i + i + 1}\""))
        end
      end

      perform(message)

      expect(message.reload).to have_attributes(status: "read", wa_message_id: "wamid.FAKE-EARLY")
      expect([ message.accepted_at, message.sent_at, message.delivered_at, message.read_at ]).to all(be_present)
    end

    it "keeps a failure that overtakes the response" do
      message = outbound
      graph.reply(200, ok_send("wamid.FAKE-EARLY")) do
        body = status_body("status_sent", wamid: "wamid.FAKE-EARLY", opaque: message.id)
        failed = JSON.parse(body).tap do |json|
          status = json.dig("entry", 0, "changes", 0, "value", "statuses", 0)
          status["status"] = "failed"
          status["errors"] = [ { "code" => 131026, "title" => "Message undeliverable" } ]
        end.to_json
        deliver_and_process(failed)
      end

      perform(message)

      expect(message.reload).to have_attributes(status: "failed", error_category: "recipient_undeliverable", wa_message_id: "wamid.FAKE-EARLY")
    end
  end

  describe "retryable failures" do
    it "schedules a retry for a network failure that never left, with the first backoff (30 s) and a delayed job" do
      message = outbound
      graph.fail_with(Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new))

      perform(message)

      expect(message.reload).to have_attributes(
        status: "retry_scheduled", attempts: 1, error_category: "transient_network", next_attempt_at: now + 30.seconds, wa_message_id: nil
      )
      expect(retry_jobs.sole).to include("arguments" => [ message.id ])
      expect(retry_jobs.sole[:at]).to eq((now + 30.seconds).to_f)
    end

    it "walks the whole schedule 30 s, 2 min, 10 min, 30 min and then fails with transient_exhausted" do
      message = outbound
      5.times { graph.reply(503, { "error" => { "message" => "down" } }) } # no code: HTTP 5xx fallback

      delays = 4.times.map do
        perform(message)
        expect(message.reload).to be_retry_scheduled
        (message.next_attempt_at - Time.current).to_i
      end
      expect(delays).to eq([ 30, 120, 600, 1800 ])

      perform(message)

      expect(message.reload).to have_attributes(status: "failed", attempts: 5, error_category: "transient_exhausted", failed_at: now)
      expect(retry_jobs.size).to eq(4) # nothing enqueued after exhaustion
      expect(graph.calls).to eq(5)
      expect(Message::RESENDABLE_ERROR_CATEGORIES).to include("transient_exhausted")
    end

    it "waits at least 2 minutes when rate limited" do
      message = outbound
      graph.reply(429, graph_error(130429))

      perform(message)

      expect(message.reload).to have_attributes(status: "retry_scheduled", error_category: "rate_limited", error_code: 130429, next_attempt_at: now + 2.minutes)
    end

    it "backs off 4**attempt seconds (floored at 2 minutes) for the pair rate limit 131056" do
      message = outbound
      graph.reply(400, graph_error(131056))
      4.times { graph.reply(400, graph_error(131056)) }

      waits = 4.times.map do
        perform(message)
        (message.reload.next_attempt_at - Time.current).to_i
      end

      expect(waits).to eq([ 120, 120, 120, 256 ])
    end

    it "retries platform errors by code" do
      message = outbound
      graph.reply(500, graph_error(131016))

      perform(message)

      expect(message.reload).to have_attributes(status: "retry_scheduled", error_category: "transient_platform", error_code: 131016)
    end

    it "sends the retry when the delayed job runs, ending accepted" do
      message = outbound
      graph.fail_with(Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new)).reply(200, ok_send("wamid.FAKE-R"))

      perform(message)
      perform(message)

      expect(message.reload).to have_attributes(status: "accepted", attempts: 2, wa_message_id: "wamid.FAKE-R", error_category: nil)
    end

    it "blocks instead of retrying once the window has closed in the meantime" do
      message = outbound
      open_window(conversation, at: now - 23.hours - 50.minutes)
      graph.fail_with(Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new))
      perform(message)
      expect(message.reload).to be_retry_scheduled

      travel_to(now + 10.minutes)
      perform(message)

      expect(message.reload).to have_attributes(status: "blocked", error_category: "window_closed")
      expect(graph.calls).to eq(1)
    end

    describe ".retry_delay" do
      it "follows the schedule for transient categories and gives up after four retries" do
        delays = (1..5).map { |attempt| described_class.retry_delay(attempt: attempt, category: "transient_platform")&.to_i }
        expect(delays).to eq([ 30, 120, 600, 1800, nil ])
      end

      it "floors rate limits at 2 minutes and follows 4**attempt for 131056, capped at 30 minutes" do
        expect((1..4).map { |a| described_class.retry_delay(attempt: a, category: "rate_limited").to_i }).to eq([ 120, 120, 600, 1800 ])
        expect((1..4).map { |a| described_class.retry_delay(attempt: a, category: "rate_limited", code: 131056).to_i }).to eq([ 120, 120, 120, 256 ])
        stub_const("SendMessageJob::RETRY_DELAYS", [ 1.second ] * 8)
        expect(described_class.retry_delay(attempt: 8, category: "rate_limited", code: 131056).to_i).to eq(1800)
      end
    end
  end

  describe "permanent failures" do
    it "fails with code, category, title and details, and never retries" do
      message = outbound
      body = JSON.parse(Rails.root.join("spec/fixtures/meta/v1/graph_error_131030.json").read)
      graph.reply(body["http_status"], body["body"])

      perform(message)

      expect(message.reload).to have_attributes(
        status: "failed", attempts: 1, error_code: 131030, error_category: "recipient_not_allowed", error_title: "OAuthException", failed_at: now
      )
      expect(message.error_details).to include("not in allowed list")
      expect(retry_jobs).to be_empty
    end

    it "fails with auth_config, without any HTTP call, when credentials are missing (and an operator can resend after the fix)" do
      Rails.application.config.whatsapp.token = nil
      message = outbound

      perform(message)

      expect(graph.calls).to eq(0)
      expect(message.reload).to have_attributes(status: "failed", error_category: "auth_config")
      expect(message.transition!(:pending)).to be(true)
    end

    it "fails with request_invalid when the stored request cannot be sent" do
      message = outbound(raw_payload: {})

      perform(message)

      expect(message.reload).to have_attributes(status: "failed", error_category: "request_invalid")
      expect(graph.calls).to eq(0)
    end

    it "classifies by HTTP status when Meta sent no code" do
      message = outbound
      graph.reply(401, {})

      perform(message)

      expect(message.reload).to have_attributes(status: "failed", error_category: "auth_config", error_code: nil)
    end
  end

  describe "ambiguous outcomes" do
    it "marks a read timeout unknown and never sends again, however often the job runs" do
      message = outbound
      graph.fail_with(Faraday::TimeoutError.new(Net::ReadTimeout.new))

      perform(message)

      expect(message.reload).to have_attributes(status: "unknown", attempts: 1, error_category: "ambiguous", wa_message_id: nil)
      expect(retry_jobs).to be_empty

      3.times { perform(message) }
      expect(graph.calls).to eq(1)
      expect(message.reload).to be_unknown
    end

    it "marks a connection reset after sending unknown" do
      message = outbound
      graph.fail_with(Faraday::ConnectionFailed.new(Errno::ECONNRESET.new))

      perform(message)

      expect(message.reload).to have_attributes(status: "unknown", error_category: "ambiguous")
      expect(retry_jobs).to be_empty
    end

    it "marks a 200 without a message id unknown" do
      message = outbound
      graph.reply(200, { "messaging_product" => "whatsapp" })

      perform(message)

      expect(message.reload.status).to eq("unknown")
      expect(retry_jobs).to be_empty
    end

    it "is resolved by a later status webhook correlated through our id" do
      message = outbound
      graph.fail_with(Faraday::TimeoutError.new(Net::ReadTimeout.new))
      perform(message)

      body = fixture_json("status_delivered").tap do |json|
        status = json.dig("entry", 0, "changes", 0, "value", "statuses", 0)
        status["id"] = "wamid.FAKE-LATE"
        status["biz_opaque_callback_data"] = message.id.to_s
      end.to_json
      deliver_and_process(body)

      expect(message.reload).to have_attributes(status: "delivered", wa_message_id: "wamid.FAKE-LATE")
    end
  end

  describe "a crash during the HTTP call" do
    it "leaves the row in `sending`, never resends, and lets the sweeper turn it into unknown" do
      message = outbound
      graph.fail_with(NoMethodError.new("worker died")) # not a Faraday error: escapes the job

      expect { perform(message) }.to raise_error(NoMethodError)
      expect(message.reload).to be_sending

      expect { perform(message) }.not_to raise_error # a rerun cannot claim it
      expect(graph.calls).to eq(1)

      travel_to(now + 6.minutes)
      StallSweeperJob.perform_now

      expect(message.reload.status).to eq("unknown")
      expect(retry_jobs).to be_empty
    end

    it "refreshes updated_at on every claim so the sweeper never catches a send that is in flight" do
      message = outbound(status: :retry_scheduled, attempts: 1)
      message.update_columns(updated_at: now - 1.hour)
      graph.reply(200, ok_send) { StallSweeperJob.perform_now }

      perform(message)

      expect(message.reload).to be_accepted
    end
  end

  describe "the 24-hour window" do
    let(:last_inbound) { Time.utc(2026, 10, 5, 8, 0, 0) }

    before do
      conversation.update!(last_inbound_at: last_inbound)
      travel_back
    end

    def perform_at(message, offset)
      travel_to(last_inbound + offset)
      perform(message)
    end

    it "sends one second before the 23:55:00 mark" do
      message = outbound
      graph.reply(200, ok_send)

      perform_at(message, 23.hours + 54.minutes + 59.seconds)

      expect(graph.calls).to eq(1)
      expect(message.reload).to be_accepted
    end

    it "blocks at exactly 23:55:00 without calling Meta" do
      message = outbound

      perform_at(message, 23.hours + 55.minutes)

      expect(graph.calls).to eq(0)
      expect(message.reload).to have_attributes(status: "blocked", error_category: "window_closed", attempts: 1)
      expect(message.blocked_at).to eq(last_inbound + 23.hours + 55.minutes)
      expect(retry_jobs).to be_empty
    end

    it "blocks after 24 hours and when there was never an inbound message" do
      late = outbound
      perform_at(late, 24.hours + 1.second)
      expect(late.reload).to be_blocked

      never = Customer.resolve!(whatsapp_number: "15550100099")
      unwritten = create_outbound(customer: never)
      perform(unwritten)
      expect(unwritten.reload).to be_blocked

      expect(graph.calls).to eq(0)
    end

    it "sends despite a closed window when an operator set the override, and says so loudly" do
      message = outbound(guard_override_by: "amit")
      graph.reply(200, ok_send)

      log = capture_log { perform_at(message, 30.hours) }

      expect(graph.calls).to eq(1)
      expect(message.reload).to be_accepted
      expect(log).to include("event=window.override_send").and include("by=amit").and include("message_id=#{message.id}")
    end

    it "ignores the override while the window is open (and logs nothing about it)" do
      message = outbound(guard_override_by: "amit")
      graph.reply(200, ok_send)

      log = capture_log { perform_at(message, 1.hour) }

      expect(message.reload).to be_accepted
      expect(log).not_to include("window.override_send")
    end

    describe "Meta disagreeing (131047)" do
      it "fails with window_closed and logs window_disagreement when the response says so while we thought the window open" do
        message = outbound
        graph.reply(400, graph_error(131047, message: "Re-engagement message"))

        log = capture_log { perform_at(message, 2.hours) }

        expect(message.reload).to have_attributes(status: "failed", error_category: "window_closed", error_code: 131047)
        expect(log).to include("event=window_disagreement").and include("source=send_response").and include("message_id=#{message.id}")
        expect(retry_jobs).to be_empty
      end

      it "does not call it a disagreement when the operator knowingly overrode the guard" do
        message = outbound(guard_override_by: "amit")
        graph.reply(400, graph_error(131047))

        log = capture_log { perform_at(message, 30.hours) }

        expect(message.reload).to have_attributes(status: "failed", error_category: "window_closed")
        expect(log).not_to include("window_disagreement")
      end
    end
  end

  it "logs its decisions without phone numbers, Meta ids or bodies" do
    message = outbound
    graph.reply(200, ok_send("wamid.SECRET-ID"))

    log = capture_log { perform(message) }

    expect(log).to include("event=send.accepted")
    %w[15550100004 wamid.SECRET-ID hello].each { |secret| expect(log).not_to include(secret) }
  end
end
