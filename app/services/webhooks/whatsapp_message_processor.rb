module Webhooks
  # Entry point for inbound WhatsApp Cloud API webhook payloads. Fans out
  # each entry/change/message and dispatches by message type.
  #
  # Reference payload shapes: https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples
  class WhatsappMessageProcessor
    def initialize(client: WhatsappClient.new, responder: Conversations::Responder.new)
      @client = client
      @responder = responder
    end

    def call(payload)
      Array(payload["entry"]).each do |entry|
        Array(entry["changes"]).each do |change|
          value = change["value"] || {}
          next unless value["messages"]

          contact_name = value.dig("contacts", 0, "profile", "name")
          Array(value["messages"]).each { |message| process_message(message, contact_name: contact_name) }
        end
      end
    end

    private

    def process_message(message, contact_name:)
      customer = Customer.find_or_create_by_whatsapp_number!(message["from"], display_name: contact_name)
      conversation = customer.conversation

      conversation.record_message!(
        direction: :inbound,
        message_type: message["type"],
        body: extract_body(message),
        wa_message_id: message["id"],
        raw_payload: message
      )

      case message["type"]
      when "order"
        handle_order(customer, message["order"])
      when "text"
        @responder.respond_to(customer: customer, body: message.dig("text", "body"))
        conversation.record_message!(direction: :outbound, message_type: "text", body: "(auto-reply sent)")
      else
        Rails.logger.info("[WhatsappMessageProcessor] ignoring message type=#{message['type']}")
      end
    end

    def handle_order(customer, order_payload)
      order = Order.create_from_whatsapp!(
        customer: customer,
        catalog_id: order_payload["catalog_id"],
        note: order_payload["text"],
        product_items: order_payload["product_items"] || []
      )

      summary = order.order_items.map { |i| "#{i.quantity}× #{i.product&.name || i.product_retailer_id}" }.join(", ")
      confirmation = "Thanks! We've received your order (#{summary}) — total #{order.formatted_total}. " \
                     "We'll confirm shortly. 🎉"

      @client.send_text(to: customer.whatsapp_number, body: confirmation)
      customer.conversation.record_message!(direction: :outbound, message_type: "text", body: confirmation)

      order
    end

    def extract_body(message)
      case message["type"]
      when "text" then message.dig("text", "body")
      when "order" then message.dig("order", "text")
      else nil
      end
    end
  end
end
