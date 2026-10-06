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
        ProcessWebhookDeliveryJob.perform_later(delivery.id) if delivery.received?
        delivery
      end
    end

    private

    def attributes_for(payload)
      {
        raw_body: storable_body,
        body_sha256: Digest::SHA256.hexdigest(@raw_body),
        signature_header: @signature_header,
        request_id: @request_id,
        received_at: Time.current,
        object_type: payload&.object_type,
        phone_number_id: payload&.phone_number_id,
        item_counts: payload ? payload.item_counts : {}
      }.merge(disposition(payload))
    end

    def disposition(payload)
      return { status: :unparseable, outcome: { "reason" => "invalid_json" } } if payload.nil?
      return { status: :ignored, outcome: { "reason" => "unexpected_object" } } unless payload.expected_object?
      return { status: :ignored, outcome: { "reason" => "phone_number_mismatch" } } if foreign_phone_number?(payload)

      { status: :received }
    end

    def foreign_phone_number?(payload)
      @config.phone_number_id.present? && payload.phone_number_id != @config.phone_number_id.to_s
    end

    # Valid JSON is always valid UTF-8 without NUL bytes, so only an unparseable
    # body can need cleaning. Postgres refuses both, and an exception here would
    # make Meta retry garbage forever; the hash still covers the original bytes.
    def storable_body
      body = @raw_body.dup.force_encoding(Encoding::UTF_8)
      return body if body.valid_encoding? && !body.include?("\u0000")

      body.scrub.delete("\u0000")
    end
  end
end
