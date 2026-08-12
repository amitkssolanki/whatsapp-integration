require "openssl"

module Webhooks
  class WhatsappController < ApplicationController
    skip_forgery_protection

    # GET /webhooks/whatsapp — Meta's one-time webhook verification handshake.
    def verify
      config = Rails.application.config.whatsapp

      if params["hub.mode"] == "subscribe" && params["hub.verify_token"] == config.verify_token
        render plain: params["hub.challenge"], status: :ok
      else
        head :forbidden
      end
    end

    # POST /webhooks/whatsapp — inbound message/status events.
    def receive
      unless valid_signature?
        Rails.logger.warn("[Webhooks::WhatsappController] invalid X-Hub-Signature-256 — rejecting")
        return head :unauthorized
      end

      payload = JSON.parse(request.raw_post)
      WhatsappMessageProcessor.new.call(payload)

      head :ok
    rescue JSON::ParserError => e
      Rails.logger.error("[Webhooks::WhatsappController] bad JSON: #{e.message}")
      head :bad_request
    rescue => e
      # Always ack 200 for payloads we understood but failed to process, so
      # Meta doesn't hammer retries — the error is logged for the demo to inspect.
      Rails.logger.error("[Webhooks::WhatsappController] processing error: #{e.class}: #{e.message}")
      head :ok
    end

    private

    def valid_signature?
      secret = Rails.application.config.whatsapp.app_secret
      return true if secret.blank? # allow local testing without a configured app secret

      signature_header = request.headers["X-Hub-Signature-256"].to_s
      expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)
      ActiveSupport::SecurityUtils.secure_compare(signature_header, expected)
    end
  end
end
