# Delivers one outbound message row to the WhatsApp Cloud API
# (docs/v2/DESIGN.md §1, §3, §7, §8).
#
#   1. claim     pending | retry_scheduled -> sending, in one conditional UPDATE.
#                Whoever loses exits; this is the only thing that stops two
#                workers sending the same message.
#   2. guard     24h window closed -> blocked, Meta is not called.
#   3. send      the HTTP call, outside any transaction.
#   4. record    accepted | retry_scheduled | failed | unknown, in its own
#                transaction.
#
# A message is only ever sent from the claim, so re-running this job can never
# send twice. In particular an ambiguous outcome (read timeout, reset after
# sending) becomes `unknown` and is NEVER retried: Meta has no idempotency key,
# so only a status webhook can say what happened.
class SendMessageJob < ApplicationJob
  queue_as :default

  # Waits before retry n (1-based). After the last one the message fails.
  RETRY_DELAYS = [ 30.seconds, 2.minutes, 10.minutes, 30.minutes ].freeze
  RATE_LIMIT_MIN_DELAY = 2.minutes
  PAIR_RATE_LIMIT_CODE = 131056 # Meta suggests waiting 4^X seconds
  MAX_BACKOFF = 30.minutes

  # Safe to re-run after a database hiccup: the claim cannot succeed twice.
  retry_on(*Webhooks::DeliveryProcessor::INFRASTRUCTURE_ERRORS, attempts: 3, wait: :polynomially_longer)

  # Seconds to wait before the next try, or nil when the retries are used up.
  # `attempt` is how many sends have been made so far (>= 1).
  def self.retry_delay(attempt:, category:, code: nil)
    base = RETRY_DELAYS[attempt - 1] or return nil
    return base unless category.to_s == "rate_limited"

    delay = code.to_i == PAIR_RATE_LIMIT_CODE ? [ 4**attempt, MAX_BACKOFF.to_i ].min : base.to_i
    [ delay, RATE_LIMIT_MIN_DELAY.to_i ].max.seconds
  end

  def perform(message_id)
    message = Message.outbound.find_by(id: message_id)
    return skip(message_id, "missing") unless message
    return skip(message.id, "not_claimable", status: message.status) unless claim(message)

    return unless window_allows?(message)

    result = deliver(message)
    record(message, result)
  end

  private

  def claim(message)
    message.transition!(:sending, attempts: Arel.sql("attempts + 1"), next_attempt_at: nil)
  end

  # Returns false (after blocking the message) when the window is closed.
  def window_allows?(message)
    conversation = message.conversation
    return true if conversation.window_open?

    if message.guard_override_by.present?
      AppLog.warn("window.override_send", job_id: job_id, message_id: message.id, by: message.guard_override_by,
                                          window_closes_at: conversation.window_closes_at)
      return true
    end

    blocked = message.transition!(
      :blocked,
      blocked_at: Time.current, error_category: "window_closed",
      error_title: "24-hour window closed", error_details: "Last customer message was outside the free-form window; not sent."
    )
    AppLog.event("send.blocked", job_id: job_id, message_id: message.id, reason: "window_closed") if blocked
    false
  end

  def deliver(message)
    WhatsappClient.new.send_message(
      recipient: message.conversation.customer,
      request: message.raw_payload["request"],
      callback_id: message.id
    )
  end

  def record(message, result)
    if result.success?
      record_accepted(message, result)
    elsif result.ambiguous?
      record_unknown(message, result)
    elsif result.retryable?
      record_retry(message, result)
    else
      record_failed(message, result)
    end
  end

  def record_accepted(message, result)
    Message.transaction do
      store_wa_message_id(message, result.wa_message_id)
      # Earlier attempts may have left an error behind; it no longer applies.
      Message.where(id: message.id, status: :sending).update_all(error_code: nil, error_category: nil, error_title: nil, error_details: nil)
      message.apply_lifecycle!("accepted", at: Time.current)
    end
    AppLog.event("send.accepted", job_id: job_id, message_id: message.id, attempts: message.attempts, status: message.status)
  end

  # An early status webhook (found by our opaque id) may already have stored
  # the same wa_message_id while we were still `sending`; that is fine.
  def store_wa_message_id(message, wa_message_id)
    AppLog.quietly { Message.where(id: message.id, wa_message_id: nil).update_all(wa_message_id: wa_message_id) }
    message.reload
    return if message.wa_message_id == wa_message_id

    AppLog.warn("send.wa_message_id_mismatch", job_id: job_id, message_id: message.id)
  end

  def record_retry(message, result)
    delay = self.class.retry_delay(attempt: message.attempts, category: result.category, code: result.code)
    return record_failed(message, result, category: "transient_exhausted") unless delay

    scheduled = Message.transaction do
      moved = message.transition!(:retry_scheduled, **error_attrs(result), next_attempt_at: Time.current + delay)
      (self.class.set(wait: delay).perform_later(message.id) || raise(ApplicationJob::EnqueueFailed, "SendMessageJob")) if moved
      moved
    end
    AppLog.event("send.retry_scheduled", job_id: job_id, message_id: message.id, attempts: message.attempts,
                                         category: result.category, delay_seconds: delay.to_i) if scheduled
  end

  def record_failed(message, result, category: nil)
    attrs = error_attrs(result)
    attrs[:error_category] = category if category

    return unless message.transition!(:failed, **attrs, failed_at: Time.current)

    message.log_window_disagreement(source: "send_response") if message.error_category == "window_closed"
    AppLog.event("send.failed", job_id: job_id, message_id: message.id, attempts: message.attempts,
                                category: message.error_category, code: result.code, http_status: result.http_status)
  end

  def record_unknown(message, result)
    return unless message.transition!(:unknown, **error_attrs(result))

    AppLog.event("send.unknown", job_id: job_id, message_id: message.id, category: result.category, error_class: result.title)
  end

  def error_attrs(result)
    { error_code: result.code, error_category: result.category, error_title: result.title, error_details: result.details }
  end

  def skip(message_id, reason, **fields)
    AppLog.event("send.skipped", job_id: job_id, message_id: message_id, reason: reason, **fields)
  end
end
