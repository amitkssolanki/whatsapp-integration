require "openssl"

module Demo
  # What the scripted demo runs (Demo::Simulator, Demo::IntegrationSeed) share:
  # building the Meta webhook bodies a customer or Meta would send, posting them,
  # correctly signed, to the REAL webhook endpoint in this process, running the
  # queued jobs in the foreground, and recording checks per scenario.
  #
  # The including class provides:
  #
  #   @queue          a Demo::InlineQueue (jobs run in the foreground via #drain)
  #   @scenarios      an array that collects the Scenario records
  #   #next_id(kind)  the next unique fake inbound message id
  #   #phone_number_id and #app_secret   the run-local ones in force for the run
  module Plumbing
    STATUS_STEPS = %w[sent delivered read].freeze

    private

    def scenario(key, title)
      @current = Scenario.new(key: key.to_sym, title: title, checks: [])
      yield
    rescue StandardError => e
      check("ran without raising (#{e.class}: #{Redact.scrub(e.message, limit: 120)})", false)
    ensure
      @scenarios << @current
    end

    def check(description, condition)
      @current.checks << [ description, condition ? true : false ]
    end

    def drain
      @queue.drain
    end

    def outbound(who, purpose)
      conversation = Customer.find_by!(whatsapp_number: who[:number]).conversation
      Message.outbound.where(conversation_id: conversation.id, purpose: purpose).order(:id).last!
    end

    def inbound_for(delivery)
      Message.inbound.find_by!(webhook_delivery_id: delivery.id)
    end

    # sent -> delivered -> read as separate signed webhooks, up to `through`.
    def progress(message, through:)
      return unless message.reload.wa_message_id

      customer = message.conversation.customer
      STATUS_STEPS.first(STATUS_STEPS.index(through) + 1).each do |status|
        post(status_body({ number: customer.whatsapp_number }, message, status))
        drain
      end
    end

    def envelope(value)
      {
        "object" => "whatsapp_business_account",
        "simulated" => true,
        "entry" => [ { "id" => "DEMO-WABA", "changes" => [ {
          "field" => "messages",
          "value" => { "messaging_product" => "whatsapp",
                       "metadata" => { "display_phone_number" => "15550100999", "phone_number_id" => phone_number_id } }.merge(value)
        } ] } ]
      }
    end

    def inbound_value(who, message)
      {
        "contacts" => [ { "profile" => { "name" => who[:name] }, "wa_id" => who[:number] } ],
        "messages" => [ { "from" => who[:number], "id" => next_id("in"), "timestamp" => Time.current.to_i.to_s }.merge(message) ]
      }
    end

    def text_body(who, text)
      JSON.generate(envelope(inbound_value(who, "type" => "text", "text" => { "body" => text })))
    end

    # items: [[sku, quantity, price_in_cents]]
    def order_body(who, items)
      product_items = items.map do |sku, quantity, cents|
        { "product_retailer_id" => sku, "quantity" => quantity, "item_price" => cents / 100.0, "currency" => "USD" }
      end
      order = { "catalog_id" => "DEMO-CATALOG", "text" => "", "product_items" => product_items }
      JSON.generate(envelope(inbound_value(who, "type" => "order", "order" => order)))
    end

    def status_body(who, message, status)
      JSON.generate(envelope("statuses" => [ {
        "id" => message.wa_message_id, "status" => status, "timestamp" => Time.current.to_i.to_s,
        "recipient_id" => who[:number], "biz_opaque_callback_data" => message.id.to_s
      } ]))
    end

    # POSTs a signed body to the real webhook endpoint, in process, and returns the stored delivery.
    def post(body)
      signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', app_secret, body)}"
      session.post "/webhooks/whatsapp", params: body, headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => signature }
      raise "the webhook endpoint answered #{session.response.status}" unless session.response.status == 200

      WebhookDelivery.where(body_sha256: Digest::SHA256.hexdigest(body)).order(:id).last!
    end

    # The host the in-process request claims: the deployed APP_HOST when there is one
    # (production allows only that host), localhost otherwise. HTTPS, as production forces it.
    def session
      @session ||= ActionDispatch::Integration::Session.new(Rails.application).tap do |session|
        session.host! ENV["APP_HOST"].presence || "localhost"
        session.https!
      end
    end
  end
end
