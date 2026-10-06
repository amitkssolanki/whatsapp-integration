module Ops
  # Scenario 3 helper (docs/operating/PROTOCOL.md): re-ingests one stored
  # delivery's exact bytes and signature header, as if Meta had sent it again,
  # and labels the NEW delivery `injected:repost` in the same transaction. The
  # report then keeps the re-post out of its `real` duplicate counts, so it can
  # never be mistaken for Meta's own duplicate delivery.
  #
  # It goes through Webhooks::Ingest, not HTTP: nothing leaves the process and
  # nothing is signed here (the stored signature is re-verified against the
  # stored bytes with the current app secret first, like a replay).
  class Repost
    LABEL = "injected:repost".freeze

    class Refused < StandardError; end

    def initialize(delivery_id)
      @delivery_id = delivery_id
    end

    def call
      source = WebhookDelivery.find_by(id: @delivery_id) or raise Refused, "no webhook delivery ##{@delivery_id}"
      raise Refused, "delivery ##{source.id} was purged; its body no longer exists" if source.purged?
      raise Refused, "the stored body of delivery ##{source.id} does not match its stored signature" unless source.stored_signature_valid?

      copy = WebhookDelivery.transaction do
        Webhooks::Ingest.new(raw_body: source.raw_bytes, signature_header: source.signature_header, request_id: "repost:#{source.id}").call.tap do |delivery|
          WebhookDelivery.where(id: delivery.id).update_all([ "injected_faults = array_append(injected_faults, ?)", LABEL ])
        end
      end

      AppLog.event("ops.repost", source_delivery_id: source.id, delivery_id: copy.id)
      copy.reload
    end
  end
end
