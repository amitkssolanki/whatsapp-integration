module Webhooks
  # Stores one authenticated POST and schedules its processing. Nothing here
  # calls Meta or interprets business content; the only decisions are whether
  # the body is worth processing at all.
  #
  # The delivery row and the job row are written in one transaction (Solid
  # Queue shares the primary database), so a delivery is never stored without
  # its job. Any failure propagates so the controller can answer 500 and let
  # Meta redeliver.
  class Ingest
    def initialize(raw_body:, signature_header:, request_id:, config: Rails.application.config.whatsapp)
      @raw_body = raw_body.to_s
      @signature_header = signature_header
      @request_id = request_id
      @config = config
    end

    def call
      payload = Webhooks::Payload.parse(@raw_body)

      WebhookDelivery.transaction do
        delivery = WebhookDelivery.create!(attributes_for(payload))
        (ProcessWebhookDeliveryJob.perform_later(delivery.id) || raise(ApplicationJob::EnqueueFailed, "ProcessWebhookDeliveryJob")) if delivery.received?
        delivery
      end
    end

    private

    def attributes_for(payload)
      {
        **body_attributes,
        body_sha256: Digest::SHA256.hexdigest(@raw_body),
        signature_header: @signature_header,
        request_id: @request_id,
        received_at: Time.current,
        synthetic: Demo::Sandbox.entered?, # everything created inside a demo sandbox is synthetic, by construction
        object_type: payload&.object_type,
        phone_number_id: payload&.phone_number_id(preferring: @config.phone_number_id),
        item_counts: payload ? payload.item_counts : {}
      }.merge(disposition(payload))
    end

    def disposition(payload)
      return { status: :unparseable, outcome: { "reason" => "invalid_json" } } if payload.nil?
      return { status: :ignored, outcome: { "reason" => "unexpected_object" } } unless payload.expected_object?
      return { status: :ignored, outcome: { "reason" => "phone_number_mismatch" } } if payload.all_foreign?(@config.phone_number_id)

      { status: :received }
    end

    # PostgreSQL text refuses NUL bytes and invalid UTF-8, and raising here
    # would make Meta redeliver the same garbage forever. Such a body is stored
    # twice: a scrubbed copy in raw_body (for display) and the exact bytes,
    # base64 encoded, in raw_body_base64 so the signature can still be
    # re-verified. Every other body is stored as text only.
    def body_attributes
      body = @raw_body.dup.force_encoding(Encoding::UTF_8)
      return { raw_body: body } if body.valid_encoding? && !body.include?("\u0000")

      { raw_body: body.scrub.delete("\u0000"), raw_body_base64: Base64.strict_encode64(@raw_body.b) }
    end
  end
end
