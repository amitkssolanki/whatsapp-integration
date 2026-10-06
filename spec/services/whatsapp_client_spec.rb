require "rails_helper"

RSpec.describe WhatsappClient do
  subject(:client) { described_class.new }

  before { configure_whatsapp }

  let(:phone_customer) { Customer.new(whatsapp_number: "15550100004", wa_user_id: "US.7") }
  let(:text) { { "type" => "text", "body" => "Hello there" } }
  let(:catalog) { { "type" => "catalog_message", "body" => "Browse", "thumbnail_product_retailer_id" => "MAI-006" } }

  def send_it(recipient: phone_customer, request: text, callback_id: 42)
    client.send_message(recipient: recipient, request: request, callback_id: callback_id)
  end

  describe "the request" do
    before { graph.reply(200, ok_send("wamid.OK1")) }

    it "posts JSON to /{version}/{phone_number_id}/messages with a bearer token" do
      send_it

      request = graph.requests.sole
      expect(request).to have_attributes(method: :post, path: "/v26.0/100000000000003/messages")
      expect(request.headers).to include("Authorization" => "Bearer test-token", "Content-Type" => "application/json")
    end

    it "honours the configured API version" do
      Rails.application.config.whatsapp.api_version = "v99.0"
      send_it
      expect(graph.requests.sole.path).to eq("/v99.0/100000000000003/messages")
    end

    it "builds a text body with the opaque callback id as a string" do
      send_it

      expect(graph.requests.sole.json).to eq(
        "messaging_product" => "whatsapp", "to" => "15550100004", "type" => "text",
        "text" => { "body" => "Hello there", "preview_url" => false }, "biz_opaque_callback_data" => "42"
      )
    end

    it "builds the interactive catalog_message with its thumbnail" do
      send_it(request: catalog)

      expect(graph.requests.sole.json).to eq(
        "messaging_product" => "whatsapp", "to" => "15550100004", "type" => "interactive",
        "interactive" => {
          "type" => "catalog_message", "body" => { "text" => "Browse" },
          "action" => { "name" => "catalog_message", "parameters" => { "thumbnail_product_retailer_id" => "MAI-006" } }
        },
        "biz_opaque_callback_data" => "42"
      )
    end

    it "addresses the phone number with `to` when it is known, even if a user id is too" do
      send_it

      body = graph.requests.sole.json
      expect(body).to include("to" => "15550100004")
      expect(body).not_to have_key("recipient")
    end

    it "addresses a customer without a phone number by `recipient` (business-scoped user id)" do
      send_it(recipient: Customer.new(wa_user_id: "US.7"))

      body = graph.requests.sole.json
      expect(body).to include("recipient" => "US.7")
      expect(body).not_to have_key("to")
    end

    it "accepts the stored request with symbol keys" do
      send_it(request: { type: "text", body: "Hi" })
      expect(graph.requests.sole.json.dig("text", "body")).to eq("Hi")
    end
  end

  describe "the result" do
    it "is a success carrying Meta's message id" do
      graph.reply(200, ok_send("wamid.OK1"))

      expect(send_it).to have_attributes(success?: true, error?: false, wa_message_id: "wamid.OK1", http_status: 200, category: nil, retryable: false, ambiguous: false)
    end

    it "carries code, title, details and category of a Graph error without raising (real V1 error shape)" do
      body = JSON.parse(Rails.root.join("spec/fixtures/meta/v1/graph_error_131030.json").read)
      graph.reply(body["http_status"], body["body"])

      result = send_it

      expect(result).to have_attributes(
        success?: false, http_status: 400, code: 131030, category: "recipient_not_allowed", retryable: false, ambiguous: false, wa_message_id: nil
      )
      expect(result.title).to eq("OAuthException")
      expect(result.details).to include("Recipient phone number not in allowed list")
    end

    it "classifies retryable API errors" do
      graph.reply(429, graph_error(130429)).reply(503, "<html>bad gateway</html>")

      expect(send_it).to have_attributes(category: "rate_limited", retryable: true)
      expect(send_it).to have_attributes(category: "transient_platform", retryable: true, code: nil, http_status: 503)
    end

    it "uses the HTTP status only when the body has no code" do
      graph.reply(401, {}).reply(400, graph_error(999_999))

      expect(send_it).to have_attributes(category: "auth_config", http_status: 401)
      expect(send_it).to have_attributes(category: "unclassified", code: 999_999)
    end

    it "treats 200 without a message id as ambiguous: never resend what may have been accepted" do
      graph.reply(200, { "messaging_product" => "whatsapp" })

      expect(send_it).to have_attributes(success?: false, category: "ambiguous", ambiguous: true, retryable: false, http_status: 200)
    end

    it "turns transport failures into classified results instead of raising" do
      graph.fail_with(Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new))
           .fail_with(Faraday::TimeoutError.new(Net::ReadTimeout.new))
           .fail_with(Faraday::ConnectionFailed.new(Errno::ECONNRESET.new))

      expect(send_it).to have_attributes(category: "transient_network", retryable: true, ambiguous: false, http_status: nil)
      expect(send_it).to have_attributes(category: "ambiguous", retryable: false, ambiguous: true)
      expect(send_it).to have_attributes(category: "ambiguous", ambiguous: true)
    end

    it "does not swallow programming errors" do
      graph.fail_with(NoMethodError.new("bug"))
      expect { send_it }.to raise_error(NoMethodError)
    end
  end

  describe "when it cannot build a request" do
    it "returns auth_config without any HTTP call when the token or phone number id is missing" do
      Rails.application.config.whatsapp.token = nil
      expect(send_it).to have_attributes(category: "auth_config", retryable: false, success?: false)

      configure_whatsapp
      Rails.application.config.whatsapp.phone_number_id = ""
      expect(send_it).to have_attributes(category: "auth_config")
      expect(graph.calls).to eq(0)
    end

    it "returns an auth_config error, without any HTTP call, when the phone number id is missing or not all digits" do
      [ nil, "", "  ", "12345 6789", "1234/messages", "100000000000003\n", "abc", "1e9", "https://graph.facebook.com/1", "../1" ].each do |bad|
        Rails.application.config.whatsapp.phone_number_id = bad

        expect(send_it).to have_attributes(success?: false, category: "auth_config", retryable: false, ambiguous: false,
                                           title: "phone number id missing or malformed", http_status: nil), bad.inspect
      end
      expect(graph.calls).to eq(0)
    end

    it "still sends with a numeric phone number id" do
      graph.reply(200, ok_send("wamid.OK-DIGITS"))
      Rails.application.config.whatsapp.phone_number_id = "100000000000003"

      expect(send_it).to have_attributes(success?: true)
      expect(graph.calls).to eq(1)
    end

    it "returns request_invalid without an HTTP call for an unknown or incomplete request, or an unaddressable customer" do
      expect(send_it(request: { "type" => "carousel" })).to have_attributes(category: "request_invalid")
      expect(send_it(request: { "type" => "catalog_message", "body" => "x" })).to have_attributes(category: "request_invalid")
      expect(send_it(request: { "type" => "text", "body" => "" })).to have_attributes(category: "request_invalid")
      expect(send_it(recipient: Customer.new)).to have_attributes(category: "request_invalid")
      expect(graph.calls).to eq(0)
    end
  end

  describe "connection" do
    it "uses Faraday's net_http adapter in production, with open timeout 3 s and read timeout 10 s" do
      real = described_class.new(adapter: :net_http).connection

      expect(real.builder.adapter.klass).to eq(Faraday::Adapter::NetHttp)
      expect(real.options).to have_attributes(open_timeout: 3, timeout: 10)
      expect(real.url_prefix.to_s).to eq("https://graph.facebook.com/v26.0")
    end
  end

  describe "logging" do
    it "never writes bodies, phone numbers, user ids or Meta ids" do
      graph.reply(200, ok_send("wamid.SECRETID"))

      log = capture_log { send_it }

      expect(log).to include("event=whatsapp.send").and include("message_id=42").and include("ok=true")
      %w[15550100004 US.7 wamid.SECRETID Hello test-token].each { |secret| expect(log).not_to include(secret) }
    end
  end
end
