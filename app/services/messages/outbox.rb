module Messages
  # Records a decision to say something to a customer: one pending outbound row
  # plus its SendMessageJob, atomically with whatever caused it (call it inside
  # the caller's transaction). Nothing is sent here.
  #
  # The unique idempotency key means the same decision can be taken any number
  # of times (a replayed webhook, an operator double-click) and still produces
  # exactly one message and one job. See docs/v2/DESIGN.md §4.
  module Outbox
    # Returns the new message's id, or nil when this key was queued before.
    def self.queue(conversation:, reply:, order_id: nil, webhook_delivery_id: nil)
      inserted = Message.insert(
        {
          conversation_id: conversation.id,
          direction: :outbound,
          status: :pending,
          message_type: reply.message_type,
          body: reply.body,
          purpose: reply.purpose,
          idempotency_key: reply.idempotency_key,
          order_id: order_id,
          webhook_delivery_id: webhook_delivery_id,
          raw_payload: { "request" => reply.request }
        },
        unique_by: :idempotency_key, returning: %w[id]
      )
      outbound_id = inserted.rows.dig(0, 0)
      # A failed enqueue returns false; raise so the caller's transaction rolls back
      # instead of leaving a pending row that nothing will ever send.
      (SendMessageJob.perform_later(outbound_id) || raise(ApplicationJob::EnqueueFailed, "SendMessageJob")) if outbound_id
      outbound_id
    end
  end
end
