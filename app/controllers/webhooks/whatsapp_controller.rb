module Webhooks
  # Meta's webhook endpoint. Deliberately NOT an ApplicationController: no
  # allow_browser (Meta is not a browser), no parameter wrapping, no CSRF, and
  # it never reads `params`, so the payload cannot leak into parsed-parameter
  # logging or be altered by Rails' JSON handling.
  #
  # It verifies, stores, enqueues and answers. Everything else happens in
  # ProcessWebhookDeliveryJob. See docs/v2/DESIGN.md §5.
  class WhatsappController < ActionController::Base
    wrap_parameters false
    skip_forgery_protection

    # GET /webhooks/whatsapp: Meta's one-time verification handshake.
    def verify
      query = request.query_parameters
      expected = Rails.application.config.whatsapp.verify_token

      if expected.present? && query["hub.mode"] == "subscribe" && token_matches?(query["hub.verify_token"], expected)
        render plain: query["hub.challenge"].to_s, status: :ok
      else
        head :forbidden
      end
    end

    # POST /webhooks/whatsapp: events (messages and statuses).
    def receive
      unless Whatsapp::Signature.valid?(request.raw_post, request.headers["X-Hub-Signature-256"])
        AppLog.event("webhook.rejected", request_id: request.request_id, reason: "bad_signature")
        return head :unauthorized
      end

      delivery = Webhooks::Ingest.new(
        raw_body: request.raw_post,
        signature_header: request.headers["X-Hub-Signature-256"],
        request_id: request.request_id
      ).call

      AppLog.event("webhook.stored", request_id: request.request_id, delivery_id: delivery.id,
                   status: delivery.status, item_counts: delivery.item_counts.to_json)
      head :ok
    rescue StandardError => e
      # Nothing was stored; a 500 makes Meta redeliver. Class name only: the
      # message could echo payload data.
      AppLog.event("webhook.ingest_failed", request_id: request.request_id, error_class: e.class.name)
      head :internal_server_error
    end

    private

    def token_matches?(given, expected)
      ActiveSupport::SecurityUtils.secure_compare(given.to_s, expected.to_s)
    end

    # Rails logs `Parameters: {...}` for every request from request.filtered_parameters.
    # For this endpoint the parameters are the payload, so report none.
    def process_action(*)
      request.define_singleton_method(:filtered_parameters) { {} }
      super
    end
  end
end
