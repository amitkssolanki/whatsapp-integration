# Backstop for work that died or was lost mid-flight, and the system's
# self-healing loop. Run every few minutes by config/recurring.yml.
#
#   delivery `received`   > 5 min, no live job  -> enqueue ProcessWebhookDeliveryJob again
#   delivery `processing` > 10 min              -> `failed` ("stalled"), and while it has
#                                                  had fewer than 3 attempts, enqueue it again
#   outbound `pending`    > 10 min, no live job -> enqueue SendMessageJob again
#   outbound `sending`    > 5 min               -> `unknown` (never resent)
#
# Every re-enqueue is safe because the jobs claim their row with a conditional
# UPDATE: a duplicate job finds the row already claimed (or finished) and exits,
# so re-enqueueing can never process an item or send a message twice.
# Deliveries that crash deterministically stop after MAX_DELIVERY_ATTEMPTS and
# stay `failed`, visible on the Health page for an operator.
class StallSweeperJob < ApplicationJob
  queue_as :default

  DELIVERY_STALL_AFTER = 10.minutes
  DELIVERY_REQUEUE_AFTER = 5.minutes
  SEND_STALL_AFTER = 5.minutes
  PENDING_REQUEUE_AFTER = 10.minutes
  MAX_DELIVERY_ATTEMPTS = 3

  def perform
    requeue_received_deliveries
    sweep_deliveries
    requeue_pending_sends
    sweep_sends
  end

  private

  # The enqueue is atomic with the insert (docs/v2/DESIGN.md §1), so a delivery
  # sitting in `received` means its job was lost or is long overdue.
  def requeue_received_deliveries
    WebhookDelivery.received.where(received_at: ...DELIVERY_REQUEUE_AFTER.ago).find_each do |delivery|
      next if live_job?(ProcessWebhookDeliveryJob, delivery.id)

      guarded("sweeper.delivery_requeue_failed", delivery_id: delivery.id) do
        enqueue(ProcessWebhookDeliveryJob, delivery.id)
        AppLog.event("sweeper.delivery_requeued", delivery_id: delivery.id, status: delivery.status, attempts: delivery.attempts)
      end
    end
  end

  # A delivery stuck in `processing` is failed, so it shows up on the Health
  # page and can be replayed; with attempts left it is also retried right away
  # (the job may claim `failed`).
  def sweep_deliveries
    WebhookDelivery.processing.where("COALESCE(last_attempted_at, received_at) < ?", DELIVERY_STALL_AFTER.ago).find_each do |delivery|
      guarded("sweeper.delivery_sweep_failed", delivery_id: delivery.id) do
        WebhookDelivery.transaction do
          next unless delivery.transition!(:failed, last_error_class: "Stalled", last_error_message: "stalled", processed_at: Time.current)

          retry_now = delivery.attempts < MAX_DELIVERY_ATTEMPTS
          enqueue(ProcessWebhookDeliveryJob, delivery.id) if retry_now
          AppLog.event("sweeper.delivery_stalled", delivery_id: delivery.id, attempts: delivery.attempts, retried: retry_now)
        end
      end
    end
  end

  # `pending` is claimed by SendMessageJob within moments; one that is still
  # pending after 10 minutes lost its job.
  def requeue_pending_sends
    Message.outbound.pending.where(updated_at: ...PENDING_REQUEUE_AFTER.ago).find_each do |message|
      next if live_job?(SendMessageJob, message.id)

      guarded("sweeper.send_requeue_failed", message_id: message.id) do
        enqueue(SendMessageJob, message.id)
        AppLog.event("sweeper.send_requeued", message_id: message.id)
      end
    end
  end

  # A send stuck in `sending` may or may not have reached Meta. It becomes
  # `unknown` and is resolved by the status webhook, never resent.
  def sweep_sends
    Message.outbound.sending.where(updated_at: ...SEND_STALL_AFTER.ago).find_each do |message|
      next unless message.transition!(:unknown)

      AppLog.event("sweeper.send_stalled", message_id: message.id)
    end
  end

  def enqueue(job_class, id)
    job_class.perform_later(id) || raise(ApplicationJob::EnqueueFailed, job_class.name)
  end

  # One bad row must not stop the sweep of the others.
  def guarded(event, **fields)
    yield
  rescue StandardError => e
    AppLog.event(event, **fields, error_class: e.class.name)
  end

  # True when Solid Queue still holds an unfinished, non-failed job of this
  # class for this record id. Only avoids piling up duplicates; correctness
  # never depends on it, because the jobs' claims make duplicates harmless.
  def live_job?(job_class, id)
    SolidQueue::Job.where(class_name: job_class.name, finished_at: nil)
                   .where("(arguments::jsonb -> 'arguments' ->> 0) = ?", id.to_s)
                   .where.missing(:failed_execution)
                   .exists?
  rescue ActiveRecord::StatementInvalid
    false
  end
end
