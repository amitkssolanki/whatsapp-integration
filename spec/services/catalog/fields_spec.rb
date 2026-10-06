require "rails_helper"

RSpec.describe Catalog::Fields do
  let(:category) { Category.create!(name: "Menu", slug: "menu") }
  let(:product) do
    Product.create!(name: "Margherita", sku: "MAI-006", price_cents: 1550, category: category,
                    description: "Tomato, mozzarella", image_url: "https://example.com/m.jpg")
  end

  it "maps a product to the same fields as the CSV feed" do
    expect(described_class.for(product, base_url: "https://shop.example.com")).to eq(
      "id" => "MAI-006",
      "title" => "Margherita",
      "description" => "Tomato, mozzarella",
      "availability" => "in stock",
      "condition" => "new",
      "price" => "15.50 USD",
      "link" => "https://shop.example.com/products/#{product.id}",
      "image_link" => "https://example.com/m.jpg",
      "brand" => "The Local Table"
    )
  end

  it "truncates the title to 100 characters" do
    product.name = "x" * 150
    expect(described_class.for(product)["title"].length).to eq(100)
  end

  it "falls back to the name when the description is blank and drops a missing image" do
    product.update!(description: " ", image_url: nil)
    fields = described_class.for(product)
    expect(fields["description"]).to eq("Margherita")
    expect(fields).not_to have_key("image_link")
  end

  {
    "in_stock" => "in stock",
    "out_of_stock" => "out of stock",
    "preorder" => "out of stock" # not a documented batch value
  }.each do |availability, label|
    it "sends #{availability} as #{label}" do
      product.availability = availability
      expect(described_class.for(product)["availability"]).to eq(label)
    end
  end

  describe ".price" do
    {
      1550 => "15.50 USD", 5 => "0.05 USD", 100 => "1.00 USD", 99_999 => "999.99 USD",
      1999 => "19.99 USD", 10 => "0.10 USD"
    }.each do |cents, text|
      it "formats #{cents} cents as #{text}" do
        expect(described_class.price(cents, "USD")).to eq(text)
      end
    end

    it "uses the product currency" do
      expect(described_class.price(450, "EUR")).to eq("4.50 EUR")
    end
  end

  describe ".base_url" do
    it "uses APP_HOST over https when set, localhost otherwise" do
      stub_const("ENV", ENV.to_h.merge("APP_HOST" => "menu.example.com"))
      expect(described_class.base_url).to eq("https://menu.example.com")
      stub_const("ENV", ENV.to_h.except("APP_HOST"))
      expect(described_class.base_url).to eq("http://localhost:3000")
    end
  end

  describe "Product#catalog_digest" do
    it "is stable across calls and instances" do
      expect(product.catalog_digest).to eq(Product.find(product.id).catalog_digest)
      expect(product.catalog_digest).to match(/\A\h{64}\z/)
    end

    it "does not depend on key order" do
      a = { "id" => "A", "title" => "T" }
      expect(described_class.digest(a)).to eq(described_class.digest(a.reverse_each.to_h))
    end

    it "changes when a catalog field changes and not when an unrelated one does" do
      before = product.catalog_digest
      product.update!(price_cents: 1600)
      expect(product.catalog_digest).not_to eq(before)
      same = product.catalog_digest
      product.update!(catalog_sync_error: "x")
      expect(product.catalog_digest).to eq(same)
    end
  end

  describe "Product.catalog_dirty" do
    it "includes never-synced products and products changed since the last sync" do
      synced = Product.create!(name: "A", sku: "A-1", price_cents: 100, category: category)
      synced.update_columns(catalog_synced_digest: synced.catalog_digest)
      changed = Product.create!(name: "B", sku: "B-1", price_cents: 100, category: category)
      changed.update_columns(catalog_synced_digest: changed.catalog_digest)
      changed.update!(price_cents: 200)
      never = Product.create!(name: "C", sku: "C-1", price_cents: 100, category: category)

      expect(Product.catalog_dirty).to contain_exactly(changed, never)
      expect(synced).not_to be_catalog_dirty
    end
  end
end
