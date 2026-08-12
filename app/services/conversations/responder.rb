module Conversations
  # Handles inbound free-text messages with a small set of canned replies.
  # Deliberately not an LLM/tool-calling agent (that's the voice receptionist's
  # job) — here the WhatsApp Catalog UI does the "browsing", so all this needs
  # to do is greet and point people at it.
  class Responder
    GREETING_KEYWORDS = %w[hi hello hey menu start].freeze

    def initialize(client: WhatsappClient.new)
      @client = client
    end

    def respond_to(customer:, body:)
      text = body.to_s.strip.downcase

      if GREETING_KEYWORDS.any? { |kw| text.include?(kw) }
        send_catalog_greeting(customer)
      else
        send_fallback(customer)
      end
    end

    private

    def send_catalog_greeting(customer)
      @client.send_catalog_message(
        to: customer.whatsapp_number,
        body: "Welcome to The Local Table! 🍽️ Tap below to browse our menu and " \
              "add items to your cart — send it over whenever you're ready to order.",
        thumbnail_product_retailer_id: featured_product_sku
      )
    end

    # A signature dish to feature on the catalog card. Falls back to
    # whatever's cheapest to fetch if the menu changes.
    def featured_product_sku
      Product.in_stock.find_by(sku: "MAI-006")&.sku || Product.in_stock.first&.sku
    end

    def send_fallback(customer)
      @client.send_text(
        to: customer.whatsapp_number,
        body: "Thanks for your message! Say \"menu\" any time to browse The Local Table's " \
              "catalog and place an order right here in WhatsApp."
      )
    end
  end
end
