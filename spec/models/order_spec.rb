require "rails_helper"

RSpec.describe Order, type: :model do
  describe ".create_from_whatsapp!" do
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
      expect(order.order_items.sole.quantity).to eq(3)
      expect(order.total_cents).to eq(3 * 1550)
    end

    it "still records the line item when the retailer_id doesn't match a known product" do
      order = described_class.create_from_whatsapp!(
        customer: customer, catalog_id: "CAT123", note: nil,
        product_items: [ { "product_retailer_id" => "UNKNOWN-SKU", "quantity" => "1", "item_price" => "9.99", "currency" => "USD" } ]
      )

      expect(order.order_items.sole.product).to be_nil
      expect(order.order_items.sole.product_retailer_id).to eq("UNKNOWN-SKU")
    end
  end
end
