require "rails_helper"

# Synthetic (demo) records are marked everywhere an operator sees them, so they
# are never mistaken for real traffic; real records carry no badge.
RSpec.describe "Admin synthetic badges", type: :request do
  include_context "admin operator"

  let(:real_customer) { create_customer(number: "15550100077", name: "Real Customer") }
  let(:fake_customer) { Customer.create!(whatsapp_number: "15550102001", display_name: "Demo Customer 1", synthetic: true).tap(&:create_conversation!) }

  def badges(body) = body.scan('badge badge-synthetic').size

  context "with only real data" do
    it "shows no synthetic badge on any page" do
      open_window(real_customer.conversation)
      order = create_order(customer: real_customer)
      create_outbound(customer: real_customer, status: :failed, error_category: "request_invalid", failed_at: Time.current)
      delivery = create_delivery(status: :failed)
      create_menu

      [ "/admin/health", "/admin/orders", "/admin/orders/#{order.id}", "/admin/conversations", "/admin/conversations/#{real_customer.conversation.id}",
        "/admin/deliveries", "/admin/deliveries/#{delivery.id}", "/admin/products" ].each do |path|
        get path

        expect(response).to have_http_status(:ok), path
        expect(response.body).not_to include("badge-synthetic"), path
      end
    end
  end

  context "with synthetic data" do
    let!(:order) { create_order(customer: fake_customer, review_status: :needs_review) }
    let!(:message) { create_outbound(customer: fake_customer, status: :failed, error_category: "synthetic_recipient", failed_at: Time.current) }
    let!(:delivery) { create_delivery(status: :failed, synthetic: true, last_error_class: "Injected") }
    let!(:product) do
      Product.create!(name: "Demo Soup", sku: "DEMO-AVAIL-1", price_cents: 650, synthetic: true, category: Category.create!(name: "Demo items (synthetic)", slug: "demo-items-synthetic"))
    end

    it "marks synthetic customers on the orders and conversations pages" do
      get "/admin/orders"
      expect(response.body).to include("Demo Customer 1")
      expect(badges(response.body)).to eq(1)

      get "/admin/orders/#{order.id}"
      expect(badges(response.body)).to eq(1)

      get "/admin/conversations"
      expect(badges(response.body)).to eq(1)

      get "/admin/conversations/#{fake_customer.conversation.id}"
      expect(badges(response.body)).to eq(1)
    end

    it "marks synthetic deliveries in the list, on the page, and in Health, and explains why there is no Replay" do
      get "/admin/deliveries"
      expect(badges(response.body)).to eq(1)

      get "/admin/deliveries/#{delivery.id}"
      expect(badges(response.body)).to eq(1)
      expect(response.body).to include("A synthetic delivery cannot be replayed")

      get "/admin/health"
      expect(response.body).to include("delivery ##{delivery.id}", "message ##{message.id}")
      expect(badges(response.body)).to eq(2) # the failed delivery and the failed message
    end

    it "marks synthetic products, without linking to a public page that does not exist" do
      get "/admin/products"

      expect(badges(response.body)).to eq(1)
      expect(response.body).to include("DEMO-AVAIL-1", "Demo Soup")
      expect(response.body).not_to include("/products/#{product.id}")
    end

    it "marks only the synthetic rows when both kinds are present" do
      real_order = create_order(customer: real_customer)

      get "/admin/orders"

      expect(response.body).to include("##{real_order.id}", "##{order.id}")
      expect(badges(response.body)).to eq(1)
    end
  end
end
