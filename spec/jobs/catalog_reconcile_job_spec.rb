require "rails_helper"
require "fugit"

RSpec.describe CatalogReconcileJob do
  include ActiveJob::TestHelper

  let!(:products) { create_menu }
  let(:products_path) { "/v26.0/CAT123/products" }
  let(:in_sync) do
    {
      "MAI-006" => { retailer_id: "MAI-006", name: "Item MAI-006", price: "15.50 USD", currency: "USD", availability: "in stock", review_status: "approved" },
      "BEV-001" => { retailer_id: "BEV-001", name: "Item BEV-001", price: "4.50 USD", currency: "USD", availability: "in stock", review_status: "approved" },
      "DES-003" => { retailer_id: "DES-003", name: "Item DES-003", price: "5.00 USD", currency: "USD", availability: "in stock", review_status: "approved" }
    }
  end

  before do
    configure_catalog!(sync: true)
    # Everything pushed and confirmed, unless an example says otherwise.
    products.each { |p| p.update_columns(catalog_synced_digest: p.catalog_digest) }
  end

  def reconcile(remote, **opts)
    stub_catalog_http { |s| s.get(products_path) { json_response({ data: remote.values }) } }
    described_class.perform_now(**opts)
    CatalogSyncRun.reconciles.last
  end

  def drift_of(run)
    run.result["drift"].map { |d| d.slice("type", "sku") }
  end

  it "records a clean report when Meta matches the database" do
    run = reconcile(in_sync)

    expect(run).to have_attributes(kind: "reconcile", status: "succeeded", triggered_by: "schedule", error_message: nil)
    expect(run.finished_at).to be_present
    expect(run.result).to include("drift" => [], "checked" => 3, "remote_count" => 3)
  end

  it "reports missing_remote and extra_remote" do
    remote = in_sync.except("DES-003").merge("OLD-999" => { retailer_id: "OLD-999", name: "Old thing", price: "1.00 USD", availability: "in stock" })

    run = reconcile(remote)

    expect(run.result["drift"]).to contain_exactly(
      { "type" => "missing_remote", "sku" => "DES-003" },
      { "type" => "extra_remote", "sku" => "OLD-999", "remote" => "Old thing" }
    )
  end

  it "reports price_mismatch with both prices" do
    in_sync["MAI-006"][:price] = "14.50 USD"
    run = reconcile(in_sync)
    expect(run.result["drift"]).to eq([ { "type" => "price_mismatch", "sku" => "MAI-006", "local" => "15.50 USD", "remote" => "14.50 USD" } ])
  end

  it "reports a currency difference as a price mismatch" do
    in_sync["MAI-006"][:price] = "15.50 EUR"
    expect(drift_of(reconcile(in_sync))).to eq([ { "type" => "price_mismatch", "sku" => "MAI-006" } ])
  end

  it "reads the price in whatever shape Meta returns it" do
    in_sync["MAI-006"][:price] = "$15.50"
    in_sync["BEV-001"][:price] = "450"       # minor units, with the currency field
    in_sync["DES-003"][:price] = 500         # integer minor units
    expect(reconcile(in_sync).result["drift"]).to eq([])
  end

  it "reports price_unparseable instead of guessing" do
    in_sync["MAI-006"][:price] = "fifteen"
    in_sync["BEV-001"].delete(:price)
    run = reconcile(in_sync)
    expect(drift_of(run)).to contain_exactly(
      { "type" => "price_unparseable", "sku" => "MAI-006" },
      { "type" => "price_unparseable", "sku" => "BEV-001" }
    )
  end

  it "reports availability_mismatch against what we would send" do
    in_sync["MAI-006"][:availability] = "out of stock"
    expect(drift_of(reconcile(in_sync))).to eq([ { "type" => "availability_mismatch", "sku" => "MAI-006" } ])
  end

  it "expects a preorder product to be out of stock on Meta" do
    products.first.update!(availability: :preorder)
    products.first.update_columns(catalog_synced_digest: products.first.catalog_digest)
    in_sync["MAI-006"][:availability] = "out of stock"
    expect(reconcile(in_sync).result["drift"]).to eq([])
  end

  it "tolerates availability casing and underscores" do
    in_sync["MAI-006"][:availability] = "IN_STOCK"
    expect(reconcile(in_sync).result["drift"]).to eq([])
  end

  it "reports name_mismatch" do
    in_sync["BEV-001"][:name] = "Renamed in Commerce Manager"
    run = reconcile(in_sync)
    expect(run.result["drift"]).to eq([ { "type" => "name_mismatch", "sku" => "BEV-001", "local" => "Item BEV-001", "remote" => "Renamed in Commerce Manager" } ])
  end

  it "compares against the truncated title" do
    products.first.update!(name: "x" * 120)
    products.first.update_columns(catalog_synced_digest: products.first.catalog_digest)
    in_sync["MAI-006"][:name] = "x" * 97 + "..."
    expect(reconcile(in_sync).result["drift"]).to eq([])
  end

  it "reports a review_status that is not approved, and ignores a missing one" do
    in_sync["MAI-006"][:review_status] = "rejected"
    in_sync["BEV-001"][:review_status] = "pending"
    in_sync["DES-003"].delete(:review_status)
    run = reconcile(in_sync)
    expect(run.result["drift"]).to contain_exactly(
      { "type" => "review_not_approved", "sku" => "MAI-006", "remote" => "rejected" },
      { "type" => "review_not_approved", "sku" => "BEV-001", "remote" => "pending" }
    )
  end

  it "tags field drift on a product with an unconfirmed change as pending_push" do
    products.first.update!(price_cents: 2000) # local edit not pushed yet
    run = reconcile(in_sync)
    expect(run.result["drift"]).to eq([
      { "type" => "price_mismatch", "sku" => "MAI-006", "local" => "20.00 USD", "remote" => "15.50 USD", "pending_push" => true }
    ])
  end

  it "reports several kinds at once, ordered by sku" do
    in_sync["MAI-006"][:price] = "1.00 USD"
    in_sync["BEV-001"][:availability] = "out of stock"
    run = reconcile(in_sync.except("DES-003"))
    expect(drift_of(run)).to eq([
      { "type" => "availability_mismatch", "sku" => "BEV-001" },
      { "type" => "missing_remote", "sku" => "DES-003" },
      { "type" => "price_mismatch", "sku" => "MAI-006" }
    ])
  end

  it "never corrects anything: no push, no change to any product, no extra run" do
    in_sync["MAI-006"][:price] = "1.00 USD"
    before = Product.order(:id).map(&:attributes)

    expect do
      reconcile(in_sync.except("DES-003"))
    end.not_to have_enqueued_job(CatalogPushJob)

    expect(Product.order(:id).map(&:attributes)).to eq(before)
    expect(CatalogSyncRun.pushes).to be_empty
    expect(CatalogSyncRun.count).to eq(1)
  end

  it "makes only GET requests" do
    verbs = []
    stub_catalog_http do |s|
      s.get(products_path) { |env| verbs << env.method && json_response({ data: [] }) }
    end
    described_class.perform_now
    expect(verbs).to eq([ :get ])
  end

  it "follows paging when the catalog is large" do
    stub_catalog_http do |s|
      s.get(products_path) do |env|
        if env.params["after"].nil?
          json_response({ data: in_sync.values.first(2), paging: { cursors: { after: "c1" }, next: "x" } })
        else
          json_response({ data: in_sync.values.last(1) })
        end
      end
    end
    described_class.perform_now
    run = CatalogSyncRun.reconciles.last
    expect(run.result).to include("drift" => [], "remote_count" => 3)
  end

  it "records a failed run when the read fails, and touches nothing" do
    stub_catalog_http { |s| s.get(products_path) { api_error(code: 190, message: "expired", status: 401) } }

    described_class.perform_now(by: "admin")

    run = CatalogSyncRun.reconciles.last
    expect(run).to have_attributes(status: "failed", error_message: "auth: expired", triggered_by: "admin")
    expect(Product.catalog_dirty).to be_empty
  end

  it "records a config failure when the token is missing, without HTTP" do
    configure_catalog!(token: nil, sync: true)
    stub_catalog_http { |_s| }
    described_class.perform_now(by: "admin")
    expect(CatalogSyncRun.reconciles.last.error_message).to start_with("config:")
  end

  describe "the scheduled run" do
    it "does nothing when catalog sync is disabled" do
      configure_catalog!(sync: false)
      stub_catalog_http { |_s| }
      expect { described_class.perform_now }.not_to change(CatalogSyncRun, :count)
    end

    it "still runs when an operator asks, even with sync disabled" do
      configure_catalog!(sync: false)
      expect(reconcile(in_sync, by: "admin")).to have_attributes(status: "succeeded", triggered_by: "admin")
    end
  end

  it "is scheduled daily at 3am in production" do
    recurring = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
    entry = recurring.dig("production", "catalog_reconcile")
    expect(entry).to eq("class" => "CatalogReconcileJob", "schedule" => "every day at 3am")
    cron = Fugit.parse(entry["schedule"])
    expect(cron).to be_a(Fugit::Cron)
    expect(cron.hours).to eq([ 3 ])
    expect(cron.minutes).to eq([ 0 ])
  end
end
