module Webhooks
  # Applies one inbound customer message, inside the caller's transaction.
  # See docs/v2/DESIGN.md §6.
  #
  # The inbound row is inserted with ON CONFLICT DO NOTHING on wa_message_id.
  # If no row comes back this exact message was applied before (by another
  # delivery, a retry or a replay) and ALL side effects are skipped. That one
  # statement is what makes "at-least-once" webhooks safe, including when two
  # workers race: the loser blocks on the winner's insert and then sees a
  # conflict.
  class MessageHandler
    def initialize(delivery:, value:, item:, responder: Conversations::Responder.new)
      @delivery = delivery
      @value = value
      @item = item
      @responder = responder
    end

    def call
      wa_message_id = @item["id"].presence or raise ArgumentError, "message without an id"
      from = @item["from"].presence or raise ArgumentError, "message without a sender"

      customer = Customer.resolve!(whatsapp_number: from, display_name: contact_name(from), wa_user_id: user_id(from))
      conversation = customer.conversation

      inbound_id = insert_inbound(conversation, wa_message_id)
      return result(wa_message_id, "duplicate") unless inbound_id

      touch_conversation(conversation)
      detail = react(customer, conversation, inbound_id)
      result(wa_message_id, "applied", detail)
    end

    private

    # Returns what was decided, for the outcome record.
    def react(customer, conversation, inbound_id)
      case @item["type"]
      when "order"
        order = Orders::Builder.new(customer: customer, source_message_id: inbound_id, order_payload: @item["order"]).call
        queue_reply(conversation, @responder.order_received(order: order), order_id: order.id)
        "order_id=#{order.id}"
      when "text"
        reply = @responder.reply_to_text(inbound_message_id: inbound_id, body: @item.dig("text", "body"))
        queue_reply(conversation, reply)
        "reply=#{reply.purpose}"
      else
        "type=#{@item['type']} recorded, no reply"
      end
    end

    def insert_inbound(conversation, wa_message_id)
      inserted = AppLog.quietly { insert_inbound_row(conversation, wa_message_id) }
      inserted.rows.dig(0, 0)
    end

    # The INSERT renders the payload inline, hence the quiet block above.
    def insert_inbound_row(conversation, wa_message_id)
      Message.insert(
        {
          conversation_id: conversation.id,
          direction: :inbound,
          status: :received,
          message_type: @item["type"].to_s.presence || "unknown",
          body: inbound_body,
          wa_message_id: wa_message_id,
          wa_timestamp: wa_timestamp,
          webhook_delivery_id: @delivery.id,
          raw_payload: @item
        },
        unique_by: :wa_message_id, returning: %w[id]
      )
    end

    # Pending outbound row + its send job, in the same transaction. The unique
    # idempotency key means a reprocessed inbound can never queue a second reply.
    def queue_reply(conversation, reply, order_id: nil)
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
          webhook_delivery_id: @delivery.id,
          raw_payload: { "request" => reply.request }
        },
        unique_by: :idempotency_key, returning: %w[id]
      )
      outbound_id = inserted.rows.dig(0, 0)
      SendMessageJob.perform_later(outbound_id) if outbound_id
    end

    # GREATEST ignores NULL and never moves backwards, so out-of-order
    # deliveries cannot shrink the 24-hour window.
    def touch_conversation(conversation)
      Conversation.where(id: conversation.id).update_all([
        "last_inbound_at = GREATEST(last_inbound_at, :at), last_message_at = GREATEST(last_message_at, :now), updated_at = :now",
        { at: wa_timestamp || Time.current, now: Time.current }
      ])
    end

    def inbound_body
      case @item["type"]
      when "text" then @item.dig("text", "body")
      when "order" then @item.dig("order", "text").presence
      end
    end

    def wa_timestamp
      Time.at(Integer(@item["timestamp"].to_s)).utc if @item["timestamp"].to_s.match?(/\A\d+\z/)
    end

    def contact_for(from)
      contacts = Array(@value["contacts"]).select { |contact| contact.is_a?(Hash) }
      contacts.find { |contact| contact["wa_id"] == from } || contacts.first
    end

    def contact_name(from)
      contact_for(from)&.dig("profile", "name")
    end

    def user_id(from)
      contact_for(from)&.dig("user_id").presence || @item["from_user_id"]
    end

    def result(ref, outcome, detail = nil)
      ItemResult.for("message", ref, outcome, detail)
    end
  end
end
