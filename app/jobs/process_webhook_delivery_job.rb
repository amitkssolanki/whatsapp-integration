# Applies the items of one stored webhook delivery. The processing itself is
# added in the next change; ingestion only needs the job to exist.
class ProcessWebhookDeliveryJob < ApplicationJob
  queue_as :default

  def perform(delivery_id, replay: false)
  end
end
