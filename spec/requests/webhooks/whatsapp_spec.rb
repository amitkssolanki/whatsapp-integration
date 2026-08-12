require "rails_helper"

RSpec.describe "WhatsApp webhook", type: :request do
  describe "GET /webhooks/whatsapp (verification handshake)" do
    before { Rails.application.config.whatsapp.verify_token = "expected-token" }

    it "echoes the challenge when the verify token matches" do
      get "/webhooks/whatsapp", params: { "hub.mode" => "subscribe", "hub.verify_token" => "expected-token", "hub.challenge" => "12345" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("12345")
    end

    it "rejects a mismatched verify token" do
      get "/webhooks/whatsapp", params: { "hub.mode" => "subscribe", "hub.verify_token" => "wrong", "hub.challenge" => "12345" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /webhooks/whatsapp (inbound messages)" do
    let(:category) { Category.create!(name: "Mains", slug: "mains", position: 0) }
    let!(:main) { Product.create!(name: "Brown Stew Chicken", sku: "MAI-001", price_cents: 1650, category: category, image_url: "https://example.com/a.jpg") }
    let!(:drink) { Product.create!(name: "Banana Milk Shake", sku: "BEV-003", price_cents: 450, category: category, image_url: "https://example.com/b.jpg") }

    let(:order_payload) { Rails.root.join("spec/fixtures/whatsapp_order_payload.json").read }

    context "with signature verification disabled (no app_secret configured)" do
      before { Rails.application.config.whatsapp.app_secret = nil }

      it "creates an Order with matching OrderItems from an `order` message" do
        expect {
          post "/webhooks/whatsapp", params: order_payload, headers: { "Content-Type" => "application/json" }
        }.to change(Order, :count).by(1).and change(OrderItem, :count).by(2)

        expect(response).to have_http_status(:ok)

        order = Order.last
        expect(order.customer.whatsapp_number).to eq("15559998888")
        expect(order.wa_order_note).to eq("Extra spicy please")
        expect(order.total_cents).to eq(2 * 1650 + 450)
        expect(order.order_items.map(&:product)).to contain_exactly(main, drink)
      end

      it "records the inbound message and an outbound confirmation on the conversation" do
        post "/webhooks/whatsapp", params: order_payload, headers: { "Content-Type" => "application/json" }

        conversation = Customer.find_by(whatsapp_number: "15559998888").conversation
        expect(conversation.messages.pluck(:direction, :message_type)).to eq([ [ "inbound", "order" ], [ "outbound", "text" ] ])
      end

      it "responds to a plain text greeting without creating an order" do
        text_payload = {
          object: "whatsapp_business_account",
          entry: [{ id: "WABA_ID", changes: [{ field: "messages", value: {
            contacts: [{ profile: { name: "Jordan" }, wa_id: "15559998888" }],
            messages: [{ from: "15559998888", id: "wamid.1", timestamp: "1", type: "text", text: { body: "hi" } }]
          } }] }]
        }.to_json

        expect {
          post "/webhooks/whatsapp", params: text_payload, headers: { "Content-Type" => "application/json" }
        }.not_to change(Order, :count)

        expect(response).to have_http_status(:ok)
      end
    end

    context "with an app_secret configured" do
      before { Rails.application.config.whatsapp.app_secret = "test-secret" }

      it "rejects a request with a missing/invalid signature" do
        post "/webhooks/whatsapp", params: order_payload, headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => "sha256=bogus" }

        expect(response).to have_http_status(:unauthorized)
        expect(Order.count).to eq(0)
      end

      it "accepts a request with a valid signature" do
        signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", "test-secret", order_payload)

        post "/webhooks/whatsapp", params: order_payload, headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => signature }

        expect(response).to have_http_status(:ok)
        expect(Order.count).to eq(1)
      end
    end
  end
end
