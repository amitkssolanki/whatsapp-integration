# Tiny record builders; the app has no factory library and the specs only need
# a handful of shapes.
module Builders
  def create_customer(number: "15550100004", name: "Test Customer")
    Customer.resolve!(whatsapp_number: number, display_name: name)
  end

  def create_delivery(status: :received, body: '{"object":"whatsapp_business_account","entry":[]}', **attrs)
    WebhookDelivery.create!({
      raw_body: body,
      body_sha256: Digest::SHA256.hexdigest(body),
      received_at: Time.current,
      status: status
    }.merge(attrs))
  end

  def create_outbound(status: :pending, customer: create_customer, **attrs)
    Message.create!({
      conversation: customer.conversation,
      direction: :outbound,
      message_type: "text",
      body: "hello",
      status: status
    }.merge(attrs))
  end

  def create_order(status: :received, customer: create_customer, **attrs)
    Order.create!({ customer: customer, total_cents: 0, status: status }.merge(attrs))
  end

  def create_menu(prices = { "MAI-006" => 1550, "BEV-001" => 450, "DES-003" => 500 })
    category = Category.find_or_create_by!(name: "Menu", slug: "menu") { |c| c.position = 0 }
    prices.map do |sku, cents|
      Product.create!(name: "Item #{sku}", sku: sku, price_cents: cents, category: category, image_url: "https://example.com/#{sku}.jpg")
    end
  end
end

RSpec.configure { |config| config.include Builders }
