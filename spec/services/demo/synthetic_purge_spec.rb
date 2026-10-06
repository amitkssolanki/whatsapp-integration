require "rails_helper"

RSpec.describe Demo::SyntheticPurge do
  def snapshot(records) = records.map { |record| record.reload.attributes }

  # A little of everything that is real, and everything that is synthetic.
  let!(:menu) { create_menu }
  let(:real_customer) { create_customer(number: "15550100077", name: "Real Customer") }

  def build_real
    open_window(real_customer.conversation)
    message = create_outbound(customer: real_customer, status: :accepted, wa_message_id: "wamid.REAL1")
    order = create_order(customer: real_customer, total_cents: 1550, source_message: message)
    OrderItem.create!(order: order, product: menu.first, product_retailer_id: "MAI-006", quantity: 1, item_price_cents: 1550)
    delivery = create_delivery(status: :processed)
    message.update!(webhook_delivery: delivery, order: order)
    [ real_customer, real_customer.conversation, message, order, order.order_items.first, delivery, *menu, menu.first.category ]
  end

  it "removes exactly the synthetic data (a full seed run's worth) and leaves every non-synthetic row untouched" do
    real = build_real
    Demo::IntegrationSeed.new.call
    legacy = Customer.create!(whatsapp_number: "+15551234567", display_name: "Jordan (demo)", synthetic: true).tap(&:create_conversation!)
    before_real = snapshot(real)
    expect(Customer.synthetic.count).to eq(12)

    counts = described_class.new.call

    expect(counts).to include(customers: 12, conversations: 12, messages: 27, orders: 8, order_items: 10, webhook_deliveries: 41, products: 4, categories: 1)
    expect(Customer.synthetic).to be_empty
    expect(Conversation.where(customer_id: legacy.id)).to be_empty
    expect(WebhookDelivery.synthetic).to be_empty
    expect(Product.synthetic).to be_empty
    expect(Category.unscoped.where(slug: Demo::IntegrationSeed::CATEGORY_SLUG)).to be_empty
    expect(snapshot(real)).to eq(before_real)
    expect(Customer.count).to eq(1)
    expect(Message.count).to eq(1)
    expect(Order.count).to eq(1)
    expect(OrderItem.count).to eq(1)
    expect(WebhookDelivery.count).to eq(1)
    expect(Product.count).to eq(menu.size)
    expect(Category.count).to eq(1)
  end

  it "previews the same counts without changing anything" do
    Demo::IntegrationSeed.new.call

    expect(described_class.new.preview).to eq(customers: 11, conversations: 11, messages: 27, orders: 8, order_items: 10, webhook_deliveries: 41, products: 4)
    expect(Customer.synthetic.count).to eq(11)
  end

  it "does nothing, and says so, when there is no synthetic data" do
    real = build_real

    expect(described_class.new.call).to eq(customers: 0, conversations: 0, messages: 0, orders: 0, order_items: 0, webhook_deliveries: 0, products: 0, categories: 0)
    expect(real.map { |record| record.class.unscoped.exists?(record.id) }).to all(be(true))
  end

  it "keeps a real delivery's messages, and the demo category when a real product shares it" do
    delivery = create_delivery(status: :processed)
    category = Category.create!(name: "Demo items (synthetic)", slug: Demo::IntegrationSeed::CATEGORY_SLUG, position: 99)
    Product.create!(name: "Shared", sku: "REAL-IN-DEMO-CAT", price_cents: 100, category: category)
    Product.create!(name: "Demo", sku: "DEMO-X", price_cents: 100, category: category, synthetic: true)
    real_message = create_outbound(customer: real_customer, webhook_delivery: delivery)

    described_class.new.call

    expect(Category.unscoped.exists?(category.id)).to be(true)
    expect(Product.pluck(:sku)).to include("REAL-IN-DEMO-CAT")
    expect(Product.where(sku: "DEMO-X")).to be_empty
    expect(real_message.reload.webhook_delivery_id).to eq(delivery.id)
  end

  it "refuses, removing nothing, when a non-synthetic order still refers to a synthetic product" do
    category = Category.create!(name: "Demo items (synthetic)", slug: Demo::IntegrationSeed::CATEGORY_SLUG, position: 99)
    demo = Product.create!(name: "Demo", sku: "DEMO-X", price_cents: 100, category: category, synthetic: true)
    order = create_order(customer: real_customer)
    OrderItem.create!(order: order, product: demo, product_retailer_id: "DEMO-X", quantity: 1, item_price_cents: 100)
    synthetic_customer = Customer.create!(whatsapp_number: "15550102001", synthetic: true)

    expect { described_class.new.call }.to raise_error(described_class::Refused, /1 order item\(s\) of non-synthetic orders/)

    expect(Product.exists?(demo.id)).to be(true)
    expect(Customer.exists?(synthetic_customer.id)).to be(true)
  end

  it "rolls back as a whole if a foreign key stops it half way" do
    Demo::IntegrationSeed.new.call
    allow(Product).to receive(:synthetic).and_wrap_original { |original| original.call.tap { raise ActiveRecord::InvalidForeignKey, "boom" if Customer.synthetic.none? } }

    expect { described_class.new.call }.to raise_error(ActiveRecord::InvalidForeignKey)

    expect(Customer.synthetic.count).to eq(11)
    expect(Message.count).to eq(27)
  end
end
