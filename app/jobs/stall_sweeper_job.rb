# Backstop for work that died mid-flight. A worker killed between claiming a
# row and finishing it leaves the row in an in-progress state forever; this
# moves such rows to a state an operator can see and act on.
#
# Run every few minutes by config/recurring.yml. Each move is a conditional
# UPDATE, so a worker that finishes at the same moment simply wins.
class StallSweeperJob < ApplicationJob
  queue_as :default

  DELIVERY_STALL_AFTER = 10.minutes
  SEND_STALL_AFTER = 5.minutes

  def perform
    sweep_deliveries
    sweep_sends
  end

  private

  # A delivery stuck in `processing` is failed, so it shows up on the Health
  # page and can be replayed.
  def sweep_deliveries
    WebhookDelivery.processing.where("COALESCE(last_attempted_at, received_at) < ?", DELIVERY_STALL_AFTER.ago).find_each do |delivery|
      next unless delivery.transition!(:failed, last_error_class: "Stalled", last_error_message: "stalled", processed_at: Time.current)

      AppLog.event("sweeper.delivery_stalled", delivery_id: delivery.id)
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
end
