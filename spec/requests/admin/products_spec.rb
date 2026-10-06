require "rails_helper"

RSpec.describe "Admin products", type: :request do
  include_context "admin operator"

  let!(:products) { create_menu }

  it "lists the menu with catalog sync state, time and error" do
    synced, failing, = products
    synced.update_columns(catalog_synced_digest: synced.catalog_digest, catalog_synced_at: Time.utc(2026, 10, 5, 9, 30))
    failing.update_columns(catalog_sync_error: "image_link is invalid for wamid.ABC")

    get "/admin/products"

    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).to include("MAI-006", "$15.50", "in stock", "Oct 5, 09:30", "image_link is invalid", "[id]", "Sync is off")
    expect(body).to include("badge-ok", "badge-warn")
    expect(body.scan("synced</span>").size).to be >= 1
    expect(body).not_to include("wamid.")
  end

  it "marks a product edited after its last push as not synced" do
    product = products.first
    product.update_columns(catalog_synced_digest: product.catalog_digest)
    product.update_columns(price_cents: 1600)

    get "/admin/products"

    expect(response.body).to include("not synced")
  end

  it "links each product to its public page" do
    get "/admin/products"

    expect(response.body).to include("href=\"/products/#{products.first.id}\"")
  end
end
