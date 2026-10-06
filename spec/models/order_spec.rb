require "rails_helper"

RSpec.describe Order, type: :model do
  def build_in_status(status) = create_order(status: status)

  it_behaves_like "a state machine"

  it "makes accepted and rejected terminal" do
    expect(described_class::ALLOWED_TRANSITIONS.keys).to eq(%w[received])
  end

  it "records who decided and why in the transition" do
    order = create_order
    order.transition!(:rejected, decided_at: Time.current, decided_by: "operator", rejection_reason: "sold out")

    expect(order.reload).to have_attributes(status: "rejected", decided_by: "operator", rejection_reason: "sold out")
  end

  it "keeps V1 status integers: 0 is received and 1 is accepted (was confirmed)" do
    expect(described_class.statuses).to include("received" => 0, "accepted" => 1, "rejected" => 2)
  end

  it "keeps review_status independent of status" do
    order = create_order(review_status: :needs_review)

    expect { order.transition!(:accepted) }.not_to change { order.reload.review_status }
  end

  describe ".create_from_whatsapp! (legacy V1 builder)" do
    let(:category) { Category.create!(name: "Mains", slug: "mains", position: 0) }
    let!(:product) { Product.create!(name: "Lasagne", sku: "MAI-006", price_cents: 1550, category: category, image_url: "https://example.com/l.jpg") }
    let(:customer) { Customer.find_or_create_by_whatsapp_number!("15550001234") }

    it "creates order items, resolving products by retailer_id (sku)" do
      order = described_class.create_from_whatsapp!(
        customer: customer,
        catalog_id: "CAT123",
        note: "No onions",
        product_items: [ { "product_retailer_id" => "MAI-006", "quantity" => "3", "item_price" => "15.50", "currency" => "USD" } ]
      )

      expect(order.order_items.sole.product).to eq(product)
      expect(order.total_cents).to eq(3 * 1550)
    end
  end
end
