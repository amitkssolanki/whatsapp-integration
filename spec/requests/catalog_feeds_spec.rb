require "rails_helper"

RSpec.describe "GET /catalog/feed.csv", type: :request do
  let(:category) { Category.create!(name: "Mains", slug: "mains", position: 0) }

  before do
    Product.create!(
      name: "Test Burger", sku: "MAI-999", price_cents: 1250, category: category,
      image_url: "https://example.com/burger.jpg", description: "A test burger.",
      availability: :in_stock
    )
  end

  it "returns a CSV with a header row and one row per product" do
    get catalog_feed_path

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")

    rows = CSV.parse(response.body, headers: true)
    expect(rows.headers).to eq(%w[id title description availability condition price link image_link brand])

    row = rows.find { |r| r["id"] == "MAI-999" }
    expect(row["title"]).to eq("Test Burger")
    expect(row["availability"]).to eq("in stock")
    expect(row["price"]).to eq("12.50 USD")
    expect(row["image_link"]).to eq("https://example.com/burger.jpg")
  end
end
