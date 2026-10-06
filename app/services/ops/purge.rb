module Ops
  # End-of-period data minimisation (docs/operating/PROTOCOL.md "After the
  # period"): removes the raw webhook bodies and message payloads, which hold
  # phone numbers, names and message text, and keeps everything aggregate
  # (statuses, timestamps, outcomes, counts, fingerprints).
  #
  #   Ops::Purge.new(before: Time.zone.parse("2026-12-01")).call  # => { deliveries:, messages:, skipped_in_flight: }
  #
  # * webhook_deliveries received before the date: raw_body '' , raw_body_base64
  #   NULL, purged_at set. A purged delivery can no longer be replayed.
  # * messages created before the date: raw_payload {}. Outbound messages that
  #   are still in flight (pending, sending, retry_scheduled) are left alone:
  #   their payload is the request about to be sent.
  #
  # Idempotent: rows already purged are not counted again. `preview` returns the
  # same counts without changing anything.
  class Purge
    IN_FLIGHT = %w[pending sending retry_scheduled].freeze

    def initialize(before:, now: Time.current)
      @before = before
      @now = now
    end

    def preview
      {
        deliveries: deliveries.count,
        messages: messages.count,
        skipped_in_flight: in_flight.count
      }
    end

    def call
      counts = ActiveRecord::Base.transaction do
        {
          deliveries: deliveries.update_all(raw_body: "", raw_body_base64: nil, purged_at: @now),
          messages: messages.update_all(raw_payload: {}),
          skipped_in_flight: in_flight.count
        }
      end
      AppLog.warn("ops.purge", before: @before.iso8601, **counts)
      counts
    end

    private

    def deliveries
      WebhookDelivery.where(received_at: ...@before, purged_at: nil)
    end

    def purgeable_messages
      Message.where(created_at: ...@before).where("messages.raw_payload <> '{}'::jsonb")
    end

    def in_flight
      purgeable_messages.outbound.where(status: IN_FLIGHT)
    end

    def messages
      purgeable_messages.where.not(id: in_flight.select(:id))
    end
  end
end
