require "rails_helper"

RSpec.describe CatalogPushJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let!(:products) { create_menu }
  let(:batch_path) { "/v26.0/CAT123/items_batch" }
  let(:sent) { [] }

  before { configure_catalog!(sync: true) }

  def stub_batch(response = json_response({ handles: [ "H1" ] }))
    stub_catalog_http do |s|
      s.post(batch_path) do |env|
        sent << Rack::Utils.parse_nested_query(env.request_body)
        response
      end
    end
  end

  def run
    CatalogSyncRun.last
  end

  it "pushes every dirty product in one UPDATE batch and queues the status check" do
    stub_batch
    freeze_time do
      expect { described_class.perform_now(triggered_by: "operator") }
        .to have_enqueued_job(CatalogBatchStatusJob).with(a_kind_of(Integer)).at(10.seconds.from_now)
    end
    expect(enqueued_jobs.last["arguments"].first).to eq(run.id)

    expect(sent.size).to eq(1)
    requests = JSON.parse(sent.first["requests"])
    expect(requests.map { |r| r["method"] }.uniq).to eq([ "UPDATE" ])
    expect(requests.map { |r| r["data"]["id"] }).to eq(%w[BEV-001 DES-003 MAI-006])
    expect(requests.last["data"]).to include("price" => "15.50 USD", "availability" => "in stock", "brand" => "The Local Table")

    expect(run).to have_attributes(
      kind: "push", status: "submitted", batch_handle: "H1", triggered_by: "operator", error_message: nil
    )
    expect(run.requested_items).to eq(products.to_h { |p| [ p.sku, p.catalog_digest ] })
    expect(run.result).to include("handles" => [ "H1" ], "push_attempts" => 1)
    expect(run.started_at).to be_present
  end

  it "does not mark anything synced: only a finished batch status does" do
    stub_batch
    described_class.perform_now
    expect(Product.catalog_dirty.count).to eq(3)
    expect(Product.where.not(catalog_synced_at: nil)).to be_empty
  end

  it "does nothing when catalog sync is disabled" do
    configure_catalog!(sync: false)
    stub_catalog_http { |_s| } # any request would raise
    expect { described_class.perform_now }.not_to change(CatalogSyncRun, :count)
  end

  it "does nothing when no product is dirty" do
    products.each { |p| p.update_columns(catalog_synced_digest: p.catalog_digest) }
    stub_catalog_http { |_s| }
    expect { described_class.perform_now }.not_to change(CatalogSyncRun, :count)
  end

  it "pushes only the dirty products" do
    products.first(2).each { |p| p.update_columns(catalog_synced_digest: p.catalog_digest) }
    stub_batch
    described_class.perform_now
    expect(JSON.parse(sent.first["requests"]).map { |r| r["data"]["id"] }).to eq([ products.last.sku ])
  end

  it "pushes everything with full: true" do
    products.each { |p| p.update_columns(catalog_synced_digest: p.catalog_digest) }
    stub_batch
    described_class.perform_now(full: true)
    expect(JSON.parse(sent.first["requests"]).size).to eq(3)
  end

  it "does not push again what an in-flight batch already carries, but does push edits made since" do
    stub_batch
    described_class.perform_now
    expect(CatalogSyncRun.count).to eq(1)

    described_class.perform_now # duplicate enqueue
    expect(CatalogSyncRun.count).to eq(1)

    products.first.update!(price_cents: 999)
    described_class.perform_now
    expect(CatalogSyncRun.count).to eq(2)
    expect(JSON.parse(sent.last["requests"]).map { |r| r["data"]["id"] }).to eq([ products.first.sku ])
  end

  it "caps a batch and leaves the rest dirty for another pass" do
    stub_const("CatalogPushJob::MAX_BATCH", 2)
    stub_batch
    expect { described_class.perform_now }.to have_enqueued_job(described_class)
    expect(run.requested_items.size).to eq(2)
  end

  describe "failures" do
    it "fails the run when Meta returns no handles" do
      stub_batch(json_response({ handles: [] }))
      expect { described_class.perform_now }.not_to have_enqueued_job(CatalogBatchStatusJob)

      expect(run.status).to eq("failed")
      expect(run.error_message).to include("empty_handles")
      expect(run.finished_at).to be_present
      expect(Product.pluck(:catalog_sync_error).uniq.first).to include("empty_handles")
      expect(Product.catalog_dirty.count).to eq(3)
    end

    it "retries an HTTP 500 on the same run, then fails visibly after 3 attempts" do
      stub_batch([ 500, {}, "oops" ])

      expect { described_class.perform_now }.to have_enqueued_job(described_class)
      expect(run).to have_attributes(status: "queued", finished_at: nil)
      expect(run.error_message).to include("transient")
      expect(run.result["push_attempts"]).to eq(1)

      expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id)
      expect(run.result["push_attempts"]).to eq(2)
      expect(run.status).to eq("queued")

      expect { described_class.perform_now(run.id) }.not_to have_enqueued_job(described_class)
      expect(run).to have_attributes(status: "failed", finished_at: be_present)
      expect(run.result["push_attempts"]).to eq(3)
      expect(run.error_message).to include("transient")
      expect(sent.size).to eq(3)
      expect(Product.catalog_dirty.count).to eq(3)
      expect(CatalogSyncRun.count).to eq(1)
    end

    it "backs off between retries" do
      stub_batch([ 500, {}, "oops" ])
      freeze_time do
        expect { described_class.perform_now }.to have_enqueued_job(described_class).at(1.minute.from_now)
        expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).at(5.minutes.from_now)
      end
    end

    it "retries a timeout" do
      stub_catalog_http { |s| s.post(batch_path) { raise Faraday::TimeoutError, "slow" } }
      expect { described_class.perform_now }.to have_enqueued_job(described_class)
      expect(run.status).to eq("queued")
    end

    it "does not retry a failure an operator has to fix" do
      stub_batch(api_error(code: 190, message: "token expired", status: 401))
      expect { described_class.perform_now }.not_to have_enqueued_job(described_class)

      expect(run.status).to eq("failed")
      expect(run.error_message).to eq("auth: token expired")
      expect(run.result["push_attempts"]).to eq(1)
    end

    it "fails with a config error, without HTTP, when the token is missing" do
      configure_catalog!(token: nil, sync: true)
      stub_catalog_http { |_s| }
      described_class.perform_now
      expect(run).to have_attributes(status: "failed")
      expect(run.error_message).to start_with("config:")
    end

    it "re-reads the products on retry so the recorded digest is the one sent" do
      stub_batch([ 500, {}, "oops" ])
      described_class.perform_now
      stale = run.requested_items[products.first.sku]

      products.first.update!(price_cents: 1234)
      stub_batch(json_response({ handles: [ "H2" ] }))
      described_class.perform_now(run.id)

      expect(run.status).to eq("submitted")
      expect(run.requested_items[products.first.sku]).to eq(products.first.reload.catalog_digest)
      expect(run.requested_items[products.first.sku]).not_to eq(stale)
      sent_prices = JSON.parse(sent.last["requests"]).to_h { |r| [ r["data"]["id"], r["data"]["price"] ] }
      expect(sent_prices[products.first.sku]).to eq("12.34 USD")
    end

    it "ignores a retry for a run that is no longer queued" do
      stub_batch
      described_class.perform_now
      expect { described_class.perform_now(run.id) }.not_to change { sent.size }
    end
  end

  describe "per-item validation errors at submit time" do
    it "records them on the run and the product but still submits the batch" do
      stub_batch(json_response({
        handles: [ "H1" ],
        validation_status: [
          { retailer_id: "BEV-001", errors: [ { message: "image_link is invalid" } ], warnings: [] },
          { retailer_id: "DES-003", errors: [], warnings: [ { message: "meh" } ] }
        ]
      }))

      expect { described_class.perform_now }.to have_enqueued_job(CatalogBatchStatusJob)

      expect(run.status).to eq("submitted")
      expect(run.result["item_errors"]).to eq("BEV-001" => [ "image_link is invalid" ])
      expect(Product.find_by(sku: "BEV-001").catalog_sync_error).to eq("image_link is invalid")
      expect(Product.find_by(sku: "DES-003").catalog_sync_error).to be_nil
    end
  end
end
