# Applies the items of one stored webhook delivery (docs/v2/DESIGN.md §6).
#
# Failures split in two. Infrastructure errors (database connection, deadlock)
# say nothing about the delivery, so the job retries. Everything else is a code
# or data problem that would fail identically on retry: the delivery is marked
# failed (or partially_failed) with the reason, and an operator replays it once
# the cause is fixed.
class ProcessWebhookDeliveryJob < ApplicationJob
  queue_as :default

  retry_on(*Webhooks::DeliveryProcessor::INFRASTRUCTURE_ERRORS, attempts: 3, wait: :polynomially_longer)

  # `replay: true` means WebhookDelivery#replay! already moved the delivery to
  # `processing` on the operator's behalf.
  def perform(delivery_id, replay: false)
    delivery = WebhookDelivery.find_by(id: delivery_id)
    return AppLog.event("webhook.job_skipped", job_id: job_id, delivery_id: delivery_id, reason: "missing") unless delivery
    return AppLog.event("webhook.job_skipped", job_id: job_id, delivery_id: delivery.id, reason: "not_claimable", status: delivery.status) unless claim(delivery, replay)

    finish(delivery, Webhooks::DeliveryProcessor.new(delivery).call)
  rescue *Webhooks::DeliveryProcessor::INFRASTRUCTURE_ERRORS => e
    record_failure(delivery, e)
    raise
  rescue StandardError => e
    record_failure(delivery, e)
  end

  private

  def claim(delivery, replay)
    return replay if delivery.processing?
    return false unless delivery.received? || delivery.failed?

    delivery.transition!(:processing, attempts: Arel.sql("attempts + 1"), last_attempted_at: Time.current)
  end

  def finish(delivery, outcome)
    final = final_status(outcome)
    error = outcome.first_error
    attrs = {
      outcome: outcome.to_h,
      processed_at: Time.current,
      last_error_class: error&.detail.to_s.split(": ", 2)&.first.presence,
      last_error_message: error&.detail
    }

    # The outcome carries Meta message ids and would otherwise show in the SQL log.
    if AppLog.quietly { delivery.transition!(final, **attrs) }
      AppLog.event("webhook.processed", job_id: job_id, delivery_id: delivery.id, status: final, summary: outcome.summary.to_json)
    else
      AppLog.event("webhook.finish_lost", job_id: job_id, delivery_id: delivery.id, status: delivery.reload.status)
    end
  end

  def final_status(outcome)
    return :ignored if outcome.results.empty?
    return :processed if outcome.errors.zero?

    outcome.errors == outcome.results.size ? :failed : :partially_failed
  end

  # Best effort: if the database is what failed, this may fail too, and the
  # stall sweeper is the backstop for a delivery left in `processing`.
  def record_failure(delivery, error)
    return unless delivery

    delivery.transition!(:failed, last_error_class: error.class.name, last_error_message: error.message.truncate(500),
                                  processed_at: Time.current)
    AppLog.event("webhook.job_failed", job_id: job_id, delivery_id: delivery.id, error_class: error.class.name)
  rescue StandardError
    nil
  end
end
