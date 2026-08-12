require "faraday"
require "json"

# Thin wrapper around the WhatsApp Cloud API (Graph API) for the handful of
# calls this demo needs: send a text reply, and proactively share the
# Catalog. See https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages
class WhatsappClient
  Error = Class.new(StandardError)

  def initialize(config: Rails.application.config.whatsapp)
    @config = config
  end

  def send_text(to:, body:)
    post(messages: {
      messaging_product: "whatsapp",
      to: to,
      type: "text",
      text: { body: body, preview_url: false }
    })
  end

  # Sends the "view catalog" native message — a card that opens the synced
  # WhatsApp Catalog directly in the chat.
  # thumbnail_product_retailer_id is required by the Graph API (not optional,
  # despite what the docs' prose implies) — omitting it fails with
  # "action['parameters'] cannot be empty" (#131009).
  def send_catalog_message(to:, body:, thumbnail_product_retailer_id:)
    post(messages: {
      messaging_product: "whatsapp",
      to: to,
      type: "interactive",
      interactive: {
        type: "catalog_message",
        body: { text: body },
        action: {
          name: "catalog_message",
          parameters: { thumbnail_product_retailer_id: thumbnail_product_retailer_id }
        }
      }
    })
  end

  private

  def post(messages:)
    unless @config.token.present? && @config.phone_number_id.present?
      Rails.logger.warn("[WhatsappClient] WHATSAPP_TOKEN/WHATSAPP_PHONE_NUMBER_ID not set — skipping send: #{messages}")
      return nil
    end

    response = connection.post("/#{@config.api_version}/#{@config.phone_number_id}/messages") do |req|
      req.headers["Authorization"] = "Bearer #{@config.token}"
      req.headers["Content-Type"] = "application/json"
      req.body = messages.to_json
    end

    unless response.success?
      Rails.logger.error("[WhatsappClient] send failed: #{response.status} #{response.body}")
      raise Error, "WhatsApp API error #{response.status}: #{response.body}"
    end

    JSON.parse(response.body)
  end

  def connection
    @connection ||= Faraday.new(url: "https://graph.facebook.com")
  end
end
