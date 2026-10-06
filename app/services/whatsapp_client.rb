require "faraday"
require "json"

# Sends one outbound message to the WhatsApp Cloud API (Graph API) and reports
# what happened as a Result. It is the only code that talks to Meta.
#
# It NEVER raises for an API or transport problem: a 4xx/5xx, a timeout and a
# refused connection all come back as an error Result, already classified
# (docs/v2/DESIGN.md §7) so the caller only has to act on it. Missing
# configuration (a missing token, a missing or non-numeric phone number id) is
# also a Result (no HTTP call is made).
#
# Never logs bodies, phone numbers or Meta ids: AppLog events carry our own
# message id, the HTTP status, Meta's error code and the category.
class WhatsappClient
  GRAPH_HOST = "https://graph.facebook.com".freeze
  OPEN_TIMEOUT = 3   # seconds to establish the connection: if this fires, nothing was sent
  READ_TIMEOUT = 10  # seconds to wait for the response: if this fires, Meta may have the message

  # `adapter` is the Faraday adapter (plus args) used for every client. Specs
  # replace it with Faraday's test adapter so nothing ever touches the network.
  class_attribute :adapter, default: [ :net_http ]

  # One outcome. On success `wa_message_id` is set; on error `category`,
  # `retryable` and `ambiguous` say what to do next (Whatsapp::ErrorClassifier).
  Result = Data.define(:success, :wa_message_id, :http_status, :code, :title, :details, :category, :retryable, :ambiguous) do
    def success? = success
    def error? = !success
    def ambiguous? = ambiguous
    def retryable? = retryable
  end

  def initialize(config: Rails.application.config.whatsapp, adapter: self.class.adapter)
    @config = config
    @adapter = Array(adapter)
  end

  # recipient:   the customer (anything with whatsapp_number and wa_user_id)
  # request:     the stored request hash: {"type"=>"text","body"=>...} or
  #              {"type"=>"catalog_message","body"=>...,"thumbnail_product_retailer_id"=>...}
  # callback_id: our messages.id; Meta echoes it on status webhooks (best effort)
  def send_message(recipient:, request:, callback_id:)
    return phone_number_id_error unless phone_number_id_valid?
    return config_error unless @config.token.present?

    payload = build_payload(recipient, request, callback_id)
    return payload if payload.is_a?(Result)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = injected_5xx(callback_id) || post_and_maybe_discard(payload, callback_id)
    log(callback_id, result, started)
    result
  rescue Faraday::Error => e
    result = from_exception(e)
    log(callback_id, result, started)
    result
  end

  def connection
    @connection ||= Faraday.new(
      url: "#{GRAPH_HOST}/#{@config.api_version}",
      request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT },
      headers: { "Authorization" => "Bearer #{@config.token}", "Content-Type" => "application/json", "Accept" => "application/json" }
    ) { |faraday| faraday.adapter(*@adapter) }
  end

  private

  # Fault injection (FaultInjection, docs/operating/PROTOCOL.md 6): a synthetic
  # 503 without calling Meta. Labeled in the details stored on the message row.
  def injected_5xx(callback_id)
    return unless FaultInjection.active?("send:5xx")

    FaultInjection.fire("send:5xx", message_id: callback_id)
    classification = Whatsapp::ErrorClassifier.classify(code: nil, http_status: 503)
    error_result(http_status: 503, title: "Service Unavailable (injected)", details: "#{FaultInjection::INJECTED_PREFIX} send:5xx: synthetic 503, Meta was not called",
                 category: classification.category)
  end

  # Fault injection (docs/operating/PROTOCOL.md 7): the real request is made,
  # then the response is thrown away, exactly as if the read timeout had fired.
  def post_and_maybe_discard(payload, callback_id)
    result = post(payload)
    return result unless FaultInjection.active?("send:read_timeout_after_send")

    FaultInjection.fire("send:read_timeout_after_send", message_id: callback_id, discarded_http_status: result.http_status, discarded_ok: result.success?)
    error_result(title: "Read timeout (injected)", details: "#{FaultInjection::INJECTED_PREFIX} send:read_timeout_after_send: the request was sent, the response was discarded",
                 category: Whatsapp::ErrorClassifier::AMBIGUOUS)
  end

  def build_payload(recipient, request, callback_id)
    address = address_for(recipient) or return invalid("The customer has neither a phone number nor a user id")
    content = content_for(request) or return invalid("Unsupported message request")

    { messaging_product: "whatsapp" }.merge(address).merge(content).merge(biz_opaque_callback_data: callback_id.to_s)
  end

  # The phone number wins when both are known (Meta does the same); a user id
  # alone is addressed as `recipient` (supported since July 2026).
  def address_for(recipient)
    if recipient.whatsapp_number.present?
      { to: recipient.whatsapp_number }
    elsif recipient.wa_user_id.present?
      { recipient: recipient.wa_user_id }
    end
  end

  def content_for(request)
    request = request.to_h.stringify_keys

    case request["type"]
    when "text"
      { type: "text", text: { body: request["body"].to_s, preview_url: false } } if request["body"].present?
    when "catalog_message"
      # thumbnail_product_retailer_id is required by Graph (not optional, despite
      # the docs' prose): without it Meta fails with #131009.
      sku = request["thumbnail_product_retailer_id"].presence or return
      {
        type: "interactive",
        interactive: {
          type: "catalog_message",
          body: { text: request["body"].to_s },
          action: { name: "catalog_message", parameters: { thumbnail_product_retailer_id: sku } }
        }
      }
    end
  end

  def post(payload)
    response = connection.post("#{@config.phone_number_id}/messages") { |req| req.body = JSON.generate(payload) }
    body = parse(response.body)

    response.success? ? from_success(response, body) : from_error(response, body)
  end

  def from_success(response, body)
    wa_message_id = Array(body["messages"]).first&.dig("id").presence
    return build_success(response.status, wa_message_id) if wa_message_id

    # Meta said OK but gave no message id: we cannot tell what happened to it.
    # Treated like a lost response, so the message is never resent.
    error_result(http_status: response.status, title: "Accepted without a message id", category: Whatsapp::ErrorClassifier::AMBIGUOUS)
  end

  def from_error(response, body)
    error = body["error"].is_a?(Hash) ? body["error"] : {}
    code = Integer(error["code"].to_s, exception: false)
    classification = Whatsapp::ErrorClassifier.classify(code: code, http_status: response.status)

    error_result(
      http_status: response.status,
      code: code,
      title: error["title"].presence || error["type"].presence,
      details: error.dig("error_data", "details").presence || error["message"].presence,
      category: classification.category
    )
  end

  def from_exception(error)
    classification = Whatsapp::ErrorClassifier.classify_exception(error)
    error_result(title: error.class.name, category: classification.category)
  end

  # The id goes straight into the request path, so anything but digits (a blank
  # value, a stray space or slash, a pasted URL) never reaches the network.
  def phone_number_id_valid?
    @config.phone_number_id.to_s.match?(/\A\d+\z/)
  end

  def phone_number_id_error
    error_result(title: "phone number id missing or malformed", details: "WHATSAPP_PHONE_NUMBER_ID must be the numeric id from Meta; no request was made",
                 category: "auth_config")
  end

  def config_error
    error_result(title: "WhatsApp is not configured", details: "WHATSAPP_TOKEN and WHATSAPP_PHONE_NUMBER_ID are required", category: "auth_config")
  end

  def invalid(details)
    error_result(title: "Message cannot be built", details: details, category: "request_invalid")
  end

  def build_success(status, wa_message_id)
    Result.new(success: true, wa_message_id: wa_message_id, http_status: status, code: nil, title: nil, details: nil,
               category: nil, retryable: false, ambiguous: false)
  end

  def error_result(category:, http_status: nil, code: nil, title: nil, details: nil)
    Result.new(
      success: false, wa_message_id: nil, http_status: http_status, code: code, title: title&.to_s&.truncate(255),
      details: details&.to_s&.truncate(1000), category: category,
      retryable: Whatsapp::ErrorClassifier.retryable?(category), ambiguous: category == Whatsapp::ErrorClassifier::AMBIGUOUS
    )
  end

  def parse(body)
    parsed = JSON.parse(body.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def log(callback_id, result, started)
    elapsed = started ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round : nil
    AppLog.event("whatsapp.send", message_id: callback_id, ok: result.success?, http_status: result.http_status, code: result.code,
                                  category: result.category, duration_ms: elapsed)
  end
end
