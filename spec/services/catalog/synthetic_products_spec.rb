require "rails_helper"

# Synthetic (demo) products exist only in this database. They must never reach
# Meta (push, reconcile), the public menu or the CSV feed, and no real customer
# can order them.
RSpec.describe "Synthetic products", type: :request do
  include ActiveJob::TestHelper

  let!(:real) { create_menu({ "MAI-006" => 1550 }).first }
  let!(:demo) do
    category = Category.create!(name: "Demo items (synthetic)", slug: "demo-items-synthetic", position: 99)
    Product.create!(name: "Demo Soup", sku: "DEMO-AVAIL-1", price_cents: 650, category: category, synthetic: true,
                    image_url: "https://example.com/demo.jpg", description: "synthetic")
  end

  describe "the public menu" do
    it "lists real products only, and 404s a synthetic product page" do
      get "/products"

      expect(response.body).to include("Item MAI-006")
      expect(response.body).not_to include("Demo Soup", "Demo items")

      get "/products/#{demo.id}"
      expect(response).to have_http_status(:not_found)
      get "/products/#{real.id}"
      expect(response).to have_http_status(:ok)
    end

    it "keeps a real product that shares a category with a synthetic one, and still shows a real empty category" do
      Product.create!(name: "Mixed Demo", sku: "DEMO-MIX", price_cents: 100, category: real.category, synthetic: true)
      Category.create!(name: "Empty", slug: "empty", position: 50)

      get "/products"

      expect(response.body).to include("Item MAI-006", "Empty")
      expect(response.body).not_to include("Mixed Demo")
    end
  end

  it "keeps synthetic products out of the CSV feed" do
    get catalog_feed_path

    ids = CSV.parse(response.body, headers: true).map { |row| row["id"] }
    expect(ids).to eq([ "MAI-006" ])
    expect(response.body).not_to include("DEMO-AVAIL-1", "Demo Soup")
  end

  describe "catalog sync" do
    before { configure_catalog!(sync: true) }

    def batch_ids
      sent = []
      stub_catalog_http { |s| s.post("/v26.0/CAT123/items_batch") { |env| sent << Rack::Utils.parse_nested_query(env.request_body); json_response({ handles: [ "H1" ] }) } }
      yield
      sent.flat_map { |body| JSON.parse(body["requests"]).map { |r| r["data"]["id"] } }
    end

    it "never enqueues the debounced push for a synthetic product, but still does for a real one" do
      clear_enqueued_jobs

      expect { Product.create!(name: "Demo 2", sku: "DEMO-2", price_cents: 100, category: demo.category, synthetic: true) }.not_to have_enqueued_job(CatalogPushJob)
      expect { demo.update!(price_cents: 700) }.not_to have_enqueued_job(CatalogPushJob)
      expect { real.update!(price_cents: 1600) }.to have_enqueued_job(CatalogPushJob)
    end

    it "is never listed by the dirty scope (it is never pushed)" do
      expect(Product.catalog_dirty).to contain_exactly(real)
    end

    it "pushes only real products, dirty pushes and full pushes alike" do
      expect(batch_ids { CatalogPushJob.perform_now }).to eq(%w[MAI-006])
      expect(batch_ids { CatalogPushJob.perform_now(full: true) }).to eq(%w[MAI-006])
      expect(demo.reload).to have_attributes(catalog_synced_digest: nil, catalog_sync_error: nil)
    end

    it "does nothing at all when only synthetic products are dirty" do
      real.update_columns(catalog_synced_digest: real.catalog_digest)
      stub_catalog_http { |_s| } # any request would raise

      expect { CatalogPushJob.perform_now }.not_to change(CatalogSyncRun, :count)
    end

    it "excludes synthetic products from Catalog::SyncNow, even a full one" do
      ids = batch_ids do
        Catalog::SyncNow.call(by: "operator", full: true)
        perform_enqueued_jobs(only: CatalogPushJob)
      end

      expect(ids).to eq(%w[MAI-006])
    end

    it "does not reconcile synthetic products: no missing_remote drift, not counted as checked" do
      real.update_columns(catalog_synced_digest: real.catalog_digest)
      remote = [ { retailer_id: "MAI-006", name: "Item MAI-006", price: "15.50 USD", currency: "USD", availability: "in stock", review_status: "approved" } ]
      stub_catalog_http { |s| s.get("/v26.0/CAT123/products") { json_response({ data: remote }) } }

      CatalogReconcileJob.perform_now(by: "operator")

      expect(CatalogSyncRun.reconciles.last.result).to include("drift" => [], "checked" => 1)
    end

    it "is not counted in the catalog status" do
      demo.update_columns(catalog_sync_error: "boom")

      status = Catalog::Status.call

      expect(status.failing_products).to be_empty
      expect(status.dirty_count).to eq(1)
    end
  end

  describe "orders" do
    def order_for(customer, sku)
      Orders::Builder.new(customer: customer, source_message_id: nil,
                          order_payload: { "catalog_id" => "X", "product_items" => [ { "product_retailer_id" => sku, "quantity" => 1, "item_price" => 6.5, "currency" => "USD" } ] }).call
    end

    it "treats a synthetic SKU as unknown for a real customer, and as a product for a synthetic one" do
      order = order_for(create_customer, "DEMO-AVAIL-1")
      expect(order).to be_needs_review
      expect(order.validation_issues.map { |i| i["code"] }).to eq(%w[unknown_sku])
      expect(order.order_items.sole.product).to be_nil

      synthetic = Customer.create!(whatsapp_number: "15550102001", synthetic: true)
      order = order_for(synthetic, "DEMO-AVAIL-1")
      expect(order).to be_clear
      expect(order.order_items.sole.product).to eq(demo)
    end
  end

  describe "the catalog greeting" do
    it "features a real product, never a synthetic one" do
      real.update!(availability: :out_of_stock)

      expect(Conversations::Responder.new.reply_to_text(inbound_message_id: 1, body: "hi")).to have_attributes(message_type: "text")

      real.update!(availability: :in_stock)
      expect(Conversations::Responder.new.reply_to_text(inbound_message_id: 1, body: "hi").request).to include("thumbnail_product_retailer_id" => "MAI-006")
    end
  end
end
