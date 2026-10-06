require "rails_helper"

# The operator UI is rebuilt later in V2; these keep the existing pages (and the
# public menu) rendering across schema changes, including the removal of the
# Order and Message default scopes.
RSpec.describe "Admin and public pages", type: :request do
  let(:category) { Category.create!(name: "Mains", slug: "mains", position: 0) }
  let!(:product) { Product.create!(name: "Lasagne", sku: "MAI-006", price_cents: 1550, category: category, image_url: "https://example.com/l.jpg") }
  let(:customer) { Customer.resolve!(whatsapp_number: "15550001234", display_name: "Jordan") }

  before do
    conversation = customer.conversation
    conversation.messages.create!(direction: :outbound, message_type: "text", body: "second", created_at: 1.minute.ago, status: :pending)
    conversation.messages.create!(direction: :inbound, message_type: "text", body: "first", created_at: 2.minutes.ago)
    Order.create!(customer: customer, total_cents: 100, created_at: 2.days.ago)
    Order.create!(customer: customer, total_cents: 200, created_at: 1.day.ago)
  end

  it "lists orders newest first" do
    get "/admin/orders"

    expect(response).to have_http_status(:ok)
    expect(response.body.index("$2.00")).to be < response.body.index("$1.00")
  end

  it "shows a conversation's messages oldest first" do
    get "/admin/conversations/#{customer.conversation.id}"

    expect(response).to have_http_status(:ok)
    expect(response.body.index("first")).to be < response.body.index("second")
  end

  it "renders the other admin and public pages" do
    [ "/admin/conversations", "/admin/products", "/admin/orders/#{Order.first.id}", "/", "/products/#{product.id}" ].each do |path|
      get path
      expect(response).to have_http_status(:ok), "#{path} returned #{response.status}"
    end
  end
end
