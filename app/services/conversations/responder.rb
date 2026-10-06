module Conversations
  # Decides WHAT to say back; it never sends anything. The webhook handler
  # persists each decision as a pending outbound message and SendMessageJob
  # delivers it later.
  #
  # Deliberately not an LLM/tool-calling agent (that's the voice receptionist's
  # job): the WhatsApp Catalog UI does the "browsing", so all this needs to do
  # is greet and point people at it.
  class Responder
    GREETING_KEYWORDS = %w[hi hello hey menu start].freeze

    # purpose:         what the message is for (stored on the row)
    # idempotency_key: one logical reply, one row, however often the inbound is reprocessed
    # message_type:    the messages.message_type column ("text" or "interactive")
    # request:         what SendMessageJob will send: type "text" or "catalog_message"
    Reply = Data.define(:purpose, :idempotency_key, :message_type, :body, :request)

    GREETING_BODY = "Welcome to The Local Table! 🍽️ Tap below to browse our menu and " \
                    "add items to your cart — send it over whenever you're ready to order.".freeze
    FALLBACK_BODY = "Thanks for your message! Say \"menu\" any time to browse The Local Table's " \
                    "catalog and place an order right here in WhatsApp.".freeze

    # `inbound_message_id` is OUR messages.id, never Meta's id (those embed phone numbers).
    def reply_to_text(inbound_message_id:, body:)
      words = body.to_s.downcase.scan(/[[:alnum:]]+/)

      if (words & GREETING_KEYWORDS).any?
        catalog_greeting(inbound_message_id)
      else
        text_reply("reply", "reply:#{inbound_message_id}", FALLBACK_BODY)
      end
    end

    # The automatic receipt is neutral on purpose: the order may still need
    # review, so it states no total and promises nothing. Acceptance states the
    # final total (see #order_accepted).
    def order_received(order:)
      count = order.order_items.sum(:quantity)
      body = "Thanks! We've received your order ##{order.id} (#{count} #{'item'.pluralize(count)}). " \
             "We'll confirm it shortly. 🎉"

      text_reply("order_received", "order:#{order.id}:received", body)
    end

    # Operator accepted the order: now the total is final, so now it is stated.
    def order_accepted(order:)
      count = order.order_items.sum(:quantity)
      body = "Good news! Your order ##{order.id} is confirmed: #{count} #{'item'.pluralize(count)}, " \
             "total #{order.formatted_total}. Thank you for choosing The Local Table! 🍽️"

      text_reply("order_accepted", "order:#{order.id}:accepted", body)
    end

    # Deliberately does not repeat the operator's reason: it is an internal
    # note (stock, kitchen capacity, a suspicious cart), not customer copy.
    def order_rejected(order:)
      body = "Sorry, we can't fulfil your order ##{order.id} right now. " \
             "You're welcome to send a new cart, or message us here and we'll help. 🙏"

      text_reply("order_rejected", "order:#{order.id}:rejected", body)
    end

    private

    def catalog_greeting(inbound_message_id)
      sku = featured_product_sku
      # A catalog card without a thumbnail is rejected by Graph (#131009), so with
      # an empty menu the greeting degrades to plain text.
      return text_reply("greeting", "greeting:#{inbound_message_id}", GREETING_BODY) unless sku

      Reply.new(
        purpose: "greeting",
        idempotency_key: "greeting:#{inbound_message_id}",
        message_type: "interactive",
        body: GREETING_BODY,
        request: { "type" => "catalog_message", "body" => GREETING_BODY, "thumbnail_product_retailer_id" => sku }
      )
    end

    def text_reply(purpose, key, body)
      Reply.new(purpose: purpose, idempotency_key: key, message_type: "text", body: body,
                request: { "type" => "text", "body" => body })
    end

    # A signature dish to feature on the catalog card; any in-stock product otherwise.
    def featured_product_sku
      products = Demo::Sandbox.active? ? Product.in_stock : Product.in_stock.non_synthetic # a synthetic SKU is not in Meta's catalog
      products.find_by(sku: "MAI-006")&.sku || products.order(:id).first&.sku
    end
  end
end
