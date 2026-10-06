require "rails_helper"

RSpec.describe Orders::Builder do
  let(:customer) { create_customer }
  let!(:products) { create_menu }
  let(:source) { create_inbound_order_message(customer) }

  def create_inbound_order_message(customer)
    Message.create!(conversation: customer.conversation, direction: :inbound, message_type: "order", wa_message_id: "wamid.#{SecureRandom.hex(4)}")
  end

  def build(items: nil, catalog_id: "100000000000006", text: "", payload: nil, source_message: source)
    payload ||= { "catalog_id" => catalog_id, "text" => text, "product_items" => items }
    described_class.new(customer: customer, source_message_id: source_message.id, order_payload: payload).call
  end

  def item(sku = "MAI-006", quantity: 1, price: 15.5, currency: "USD")
    { "product_retailer_id" => sku, "quantity" => quantity, "item_price" => price, "currency" => currency }
  end

  def issues_of(order) = order.validation_issues.map { |i| i["code"] }

  describe "the real V1 cart (3 lines, numeric types)" do
    let(:payload) { JSON.parse(meta_fixture("order")).dig("entry", 0, "changes", 0, "value", "messages", 0, "order") }
    let(:order) { build(payload: payload) }

    it "records three priced lines exactly, linked to the products and the source message" do
      expect(order.order_items.map { |i| [ i.product_retailer_id, i.quantity, i.item_price_cents ] })
        .to match_array([ [ "MAI-006", 1, 1550 ], [ "BEV-001", 1, 450 ], [ "DES-003", 1, 500 ] ])
      expect(order.order_items.map(&:product)).to match_array(products)
      expect(order).to have_attributes(total_cents: 2500, status: "received", review_status: "clear", source_message_id: source.id)
    end

    it "flags nothing when everything matches (the catalog id is not configured here, so it is not checked)" do
      expect(order.validation_issues).to eq([])
    end
  end

  describe "price parsing" do
    it "parses numbers and strings through BigDecimal, never floats" do
      order = build(items: [ item("MAI-006", price: 15.5), item("BEV-001", price: "4.50"), item("DES-003", price: 5) ])

      expect(order.order_items.order(:id).pluck(:item_price_cents)).to eq([ 1550, 450, 500 ])
    end

    it "is exact where Float arithmetic is not" do
      create_menu("FLT-001" => 1010, "FLT-002" => 1155)
      # 10.1 * 100 is 1009.9999999999999 and 11.55 * 100 is 1155.0000000000002 in Float
      order = build(items: [ item("FLT-001", price: 10.1), item("FLT-002", price: 11.55) ])

      expect(order.order_items.order(:id).pluck(:item_price_cents)).to eq([ 1010, 1155 ])
      expect(order.validation_issues).to eq([])
    end

    it "accepts the old string-typed sample payload too" do
      payload = JSON.parse(Rails.root.join("spec/fixtures/whatsapp_order_payload.json").read).dig("entry", 0, "changes", 0, "value", "messages", 0, "order")
      create_menu("MAI-001" => 1650, "BEV-003" => 450)

      order = build(payload: payload)

      expect(order).to have_attributes(total_cents: 2 * 1650 + 450, wa_order_note: "Extra spicy please")
    end
  end

  describe "§9 rules" do
    it "unknown SKU: keeps the line with no product and flags unknown_sku" do
      order = build(items: [ item("NOPE-1", price: 9.99) ])

      expect(order.order_items.sole).to have_attributes(product: nil, product_retailer_id: "NOPE-1", item_price_cents: 999, catalog_price_cents: nil)
      expect(order.validation_issues).to eq([ { "code" => "unknown_sku", "sku" => "NOPE-1", "expected" => "a product in the catalog", "actual" => "NOPE-1" } ])
      expect(order).to be_needs_review
    end

    it "price differs from ours: prices the line at what the customer saw, stores our price, flags price_mismatch" do
      order = build(items: [ item("MAI-006", quantity: 2, price: 14) ])

      expect(order.order_items.sole).to have_attributes(item_price_cents: 1400, catalog_price_cents: 1550)
      expect(order.total_cents).to eq(2800)
      expect(order.validation_issues).to eq([ { "code" => "price_mismatch", "sku" => "MAI-006", "expected" => 1550, "actual" => 1400 } ])
      expect(order).to be_needs_review
    end

    it "stores our current price on matching lines without flagging them" do
      order = build(items: [ item("MAI-006") ])

      expect(order.order_items.sole.catalog_price_cents).to eq(1550)
      expect(order).to be_clear
    end

    it "product out of stock locally: keeps the line and flags unavailable" do
      Product.find_by!(sku: "MAI-006").out_of_stock!

      order = build(items: [ item("MAI-006") ])

      expect(order.order_items.sole.quantity).to eq(1)
      expect(issues_of(order)).to eq([ "unavailable" ])
    end

    it "quantity not an integer >= 1: drops the line and flags invalid_quantity" do
      [ 0, -2, 1.5, "abc", nil, "2.0", 2**40 ].each do |bad|
        order = build(items: [ item("MAI-006", quantity: bad), item("BEV-001", price: 4.5) ], source_message: create_inbound_order_message(customer))

        expect(order.order_items.pluck(:product_retailer_id)).to eq([ "BEV-001" ]), "quantity #{bad.inspect}"
        expect(issues_of(order)).to eq([ "invalid_quantity" ]), "quantity #{bad.inspect}"
        expect(order.total_cents).to eq(450)
      end
    end

    it "accepts a numeric string quantity" do
      expect(build(items: [ item("MAI-006", quantity: "3") ]).order_items.sole.quantity).to eq(3)
    end

    it "currency differs from the product's: flags currency_mismatch" do
      order = build(items: [ item("MAI-006", currency: "EUR") ])

      expect(order.validation_issues).to eq([ { "code" => "currency_mismatch", "sku" => "MAI-006", "expected" => "USD", "actual" => "EUR" } ])
      expect(order.order_items.sole.currency).to eq("EUR")
    end

    it "catalog_id differs from the configured CATALOG_ID: flags unknown_catalog" do
      Rails.application.config.whatsapp.catalog_id = "OURS"

      order = build(items: [ item("MAI-006") ], catalog_id: "SOMEONE-ELSES")

      expect(order.validation_issues).to eq([ { "code" => "unknown_catalog", "sku" => nil, "expected" => "OURS", "actual" => "SOMEONE-ELSES" } ])
    end

    it "does not check the catalog id when none is configured, and accepts the configured one" do
      expect(issues_of(build(items: [ item("MAI-006") ], catalog_id: "ANY"))).to be_empty

      Rails.application.config.whatsapp.catalog_id = "OURS"
      expect(issues_of(build(items: [ item("MAI-006") ], catalog_id: "OURS", source_message: create_inbound_order_message(customer)))).to be_empty
    end

    it "no usable lines: keeps an empty order flagged malformed" do
      [ [], nil, [ item("MAI-006", quantity: 0) ], [ "junk" ] ].each do |items|
        order = build(items: items, source_message: create_inbound_order_message(customer))

        expect(order.order_items).to be_empty
        expect(order.total_cents).to eq(0)
        expect(issues_of(order)).to include("malformed")
        expect(order).to be_needs_review
      end
    end

    it "an unparseable price drops the line and flags invalid_price" do
      order = build(items: [ item("MAI-006", price: "free"), item("BEV-001", price: nil), item("DES-003", price: -1) ])

      expect(order.order_items).to be_empty
      expect(issues_of(order)).to eq(%w[invalid_price invalid_price invalid_price malformed])
    end

    it "order object missing: raises, so the item fails and stays replayable" do
      [ nil, "oops", [] ].each do |missing|
        builder = described_class.new(customer: customer, source_message_id: source.id, order_payload: missing)

        expect { builder.call }.to raise_error(Orders::Builder::MissingOrder)
      end
      expect(Order.count).to eq(0)
    end

    it "never auto-rejects and sets no quantity cap" do
      order = build(items: [ item("MAI-006", quantity: 5000, price: 1) ])

      expect(order).to have_attributes(status: "received", total_cents: 5000 * 100)
    end

    it "total is the sum of the prices the customer saw, across mismatched lines" do
      order = build(items: [ item("MAI-006", quantity: 2, price: 10), item("BEV-001", quantity: 3, price: 4.5) ])

      expect(order.total_cents).to eq(2 * 1000 + 3 * 450)
    end
  end

  it "creates the order only once per source message" do
    build(items: [ item("MAI-006") ])

    expect { build(items: [ item("MAI-006") ]) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
