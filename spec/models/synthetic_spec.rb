require "rails_helper"

RSpec.describe Synthetic do
  it "defaults to false and splits customers, products and deliveries into synthetic and not" do
    category = Category.create!(name: "Menu", slug: "menu")
    real_customer = create_customer(number: "15550100001")
    fake_customer = Customer.create!(whatsapp_number: "15550102001", synthetic: true)
    real_product = Product.create!(name: "Soup", sku: "REAL-1", price_cents: 500, category: category)
    fake_product = Product.create!(name: "Demo soup", sku: "DEMO-1", price_cents: 500, category: category, synthetic: true)
    real_delivery = create_delivery
    fake_delivery = create_delivery(synthetic: true)

    expect([ real_customer, real_product, real_delivery ]).to all(have_attributes(synthetic: false))
    expect(Customer.synthetic).to contain_exactly(fake_customer)
    expect(Customer.non_synthetic).to contain_exactly(real_customer)
    expect(Product.synthetic).to contain_exactly(fake_product)
    expect(Product.non_synthetic).to contain_exactly(real_product)
    expect(WebhookDelivery.synthetic).to contain_exactly(fake_delivery)
    expect(WebhookDelivery.non_synthetic).to contain_exactly(real_delivery)
  end

  it "has the flag not null with an index on each table" do
    %w[customers products webhook_deliveries].each do |table|
      column = ActiveRecord::Base.connection.columns(table).find { |c| c.name == "synthetic" }
      expect(column).to have_attributes(null: false, default: "false")
      expect(ActiveRecord::Base.connection.indexes(table).map(&:columns)).to include([ "synthetic" ])
    end
  end
end
