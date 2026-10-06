module Ops
  # End-of-period data minimisation (docs/operating/PROTOCOL.md "After the
  # period"). Participants were told their phone number and name are stored
  # "until the purge date"; this removes everything that identifies them or
  # holds what they wrote, and keeps every aggregate (statuses, timestamps,
  # outcomes, counts, fingerprints), so `ops:report` gives the same numbers
  # before and after.
  #
  #   Ops::Purge.new(before: Time.zone.parse("2026-12-01")).call
  #   # => { deliveries:, messages:, customers:, orders:, skipped_deliveries:, skipped_messages:, skipped_customers:, ... }
  #
  # For records created (received, for deliveries) before the date:
  #
  # * webhook_deliveries: raw_body '' , raw_body_base64 NULL, purged_at set, and
  #   the Meta ids in the item outcomes (`ref`, which embed phone numbers)
  #   replaced by a short hash. A purged delivery can no longer be replayed.
  # * messages: body NULL, raw_payload {}, wa_message_id NULL, error_details
  #   NULL, purged_at set. A purged message can no longer be resent or requeued.
  # * orders: wa_order_note NULL.
  # * customers whose LAST activity (creation, last message in either
  #   direction, last order) is before the date: display_name NULL,
  #   whatsapp_number NULL, wa_user_id "purged:<customer id>" (the identity
  #   check constraint needs one), purged_at set. A customer who wrote again
  #   after the date keeps their data.
  #
  # Records that are still being worked on are SKIPPED and reported, never
  # silently lost, unless `force: true`:
  #
  # * deliveries received / processing / failed / partially_failed (items not
  #   applied yet; the body is what a replay needs);
  # * outbound messages pending / sending / retry_scheduled (the request about
  #   to be sent), failed (resendable) and unknown (waiting for a status that
  #   will name its wa_message_id);
  # * customers who have such an outbound message (they must stay reachable).
  #
  # Idempotent: rows already purged are not counted again. `preview` returns the
  # same counts without changing anything.
  class Purge
    HELD_DELIVERY_STATUSES = %w[received processing failed partially_failed].freeze
    HELD_MESSAGE_STATUSES = %w[pending sending retry_scheduled failed unknown].freeze
    PURGED_USER_ID_PREFIX = "purged:".freeze

    # Customers whose newest sign of life is before :before.
    LAST_ACTIVITY_BEFORE = <<~SQL.squish.freeze
      customers.id IN (
        SELECT cu.id FROM customers cu
        LEFT JOIN conversations conv ON conv.customer_id = cu.id
        WHERE GREATEST(
          cu.created_at, conv.last_inbound_at, conv.last_message_at,
          (SELECT MAX(m.created_at) FROM messages m WHERE m.conversation_id = conv.id),
          (SELECT MAX(o.created_at) FROM orders o WHERE o.customer_id = cu.id)
        ) < :before
      )
    SQL

    class FutureDate < ArgumentError; end

    def initialize(before:, force: false, now: Time.current)
      raise FutureDate, "BEFORE must not be in the future" if before > now

      @before = before
      @force = force
      @now = now
    end

    def preview
      {
        deliveries: deliveries.count,
        messages: messages.count,
        customers: customers.count,
        orders: orders.count,
        skipped_deliveries: held_deliveries.count,
        skipped_messages: held_messages.count,
        skipped_customers: held_customers.count,
        held: held_breakdown
      }
    end

    def call
      counts = ActiveRecord::Base.transaction do
        # Counted first: the customer scope reads message statuses that do not
        # change here, but the held counts must describe what was left behind.
        held = preview.slice(:skipped_deliveries, :skipped_messages, :skipped_customers, :held)
        customer_ids = customers.pluck(:id)

        {
          deliveries: purge_deliveries,
          messages: messages.update_all(body: nil, raw_payload: {}, wa_message_id: nil, error_details: nil, purged_at: @now),
          customers: anonymise_customers(customer_ids),
          orders: orders.update_all(wa_order_note: nil)
        }.merge(held)
      end
      AppLog.warn("ops.purge", before: @before.iso8601, force: @force, **counts.except(:held))
      counts
    end

    private

    def purge_deliveries
      count = 0
      deliveries.find_each do |delivery|
        delivery.update_columns(raw_body: "", raw_body_base64: nil, purged_at: @now, outcome: scrubbed_outcome(delivery.outcome))
        count += 1
      end
      count
    end

    # The item refs are Meta message ids; keep a stable fingerprint, drop the id.
    def scrubbed_outcome(outcome)
      items = outcome.is_a?(Hash) ? outcome["items"] : nil
      return outcome unless items.is_a?(Array)

      outcome.merge("items" => items.map { |item|
        item.is_a?(Hash) && item["ref"].present? ? item.merge("ref" => "purged:#{Digest::SHA256.hexdigest(item['ref'].to_s)[0, 12]}") : item
      })
    end

    def anonymise_customers(ids)
      return 0 if ids.empty?

      sql = <<~SQL.squish
        purged_had_phone = (whatsapp_number IS NOT NULL),
        display_name = NULL,
        whatsapp_number = NULL,
        wa_user_id = :prefix || id,
        purged_at = :now
      SQL
      Customer.where(id: ids).update_all([ sql, { prefix: PURGED_USER_ID_PREFIX, now: @now } ])
    end

    def deliveries
      scope = WebhookDelivery.where(received_at: ...@before, purged_at: nil)
      @force ? scope : scope.where.not(status: HELD_DELIVERY_STATUSES)
    end

    def held_deliveries
      @force ? WebhookDelivery.none : WebhookDelivery.where(received_at: ...@before, purged_at: nil, status: HELD_DELIVERY_STATUSES)
    end

    def unpurged_messages
      Message.where(created_at: ...@before, purged_at: nil)
    end

    def held_messages_scope
      unpurged_messages.outbound.where(status: HELD_MESSAGE_STATUSES)
    end

    def held_messages
      @force ? Message.none : held_messages_scope
    end

    def messages
      @force ? unpurged_messages : unpurged_messages.where.not(id: held_messages_scope.select(:id))
    end

    def orders
      Order.where(created_at: ...@before).where.not(wa_order_note: nil)
    end

    def unpurged_customers
      Customer.where(purged_at: nil).where(LAST_ACTIVITY_BEFORE, before: @before)
    end

    def held_customers
      return Customer.none if @force

      unpurged_customers.where(id: Conversation.where(id: Message.outbound.where(status: HELD_MESSAGE_STATUSES).select(:conversation_id)).select(:customer_id))
    end

    def customers
      @force ? unpurged_customers : unpurged_customers.where.not(id: held_customers.select(:id))
    end

    def held_breakdown
      return { deliveries: {}, messages: {} } if @force

      {
        deliveries: held_deliveries.group(:status).count,
        messages: held_messages.group(:status).count
      }
    end
  end
end
