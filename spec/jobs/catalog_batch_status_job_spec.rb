require "rails_helper"

RSpec.describe CatalogBatchStatusJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let!(:products) { create_menu }
  let(:status_path) { "/v26.0/CAT123/check_batch_request_status" }
  let(:digests) { products.to_h { |p| [ p.sku, p.catalog_digest ] } }
  let!(:run) do
    CatalogSyncRun.create!(
      kind: "push", status: "submitted", batch_handle: "H1", requested_items: digests,
      result: { "handles" => [ "H1" ], "push_attempts" => 1 }, started_at: Time.current
    )
  end

  before { configure_catalog!(sync: true) }

  def stub_status(response)
    stub_catalog_http { |s| s.get(status_path) { response } }
  end

  def entry(**attrs)
    json_response({ data: [ { handle: "H1", status: "finished", errors_total_count: 0 }.merge(attrs) ] })
  end

  describe "a finished batch" do
    it "settles the run and marks every product synced at the digest that was sent" do
      products.each { |p| p.update_columns(catalog_sync_error: "old error") }
      stub_status(entry)

      freeze_time do
        described_class.perform_now(run.id)

        expect(run.reload).to have_attributes(status: "succeeded", error_message: nil, finished_at: Time.current)
        expect(run.result).to include("synced_count" => 3, "failed_count" => 0)
        products.each do |product|
          product.reload
          expect(product.catalog_synced_digest).to eq(digests[product.sku])
          expect(product.catalog_synced_at).to eq(Time.current)
          expect(product.catalog_sync_error).to be_nil
        end
      end
      expect(Product.catalog_dirty).to be_empty
    end

    it "leaves a product edited while the batch was in flight dirty" do
      edited = products.first
      edited.update!(price_cents: 2000)
      stub_status(entry)

      described_class.perform_now(run.id)

      expect(run.reload.status).to eq("succeeded")
      expect(edited.reload.catalog_synced_digest).to eq(digests[edited.sku])
      expect(edited.catalog_synced_digest).not_to eq(edited.catalog_digest)
      expect(Product.catalog_dirty).to contain_exactly(edited)
      expect(products.drop(1).map { |p| p.reload.catalog_dirty? }).to eq([ false, false ])
    end

    it "marks the run partially failed and keeps rejected products dirty with their error" do
      stub_status(entry(
        errors: [ { id: "DES-003", message: "price is missing" }, { id: "DES-003", message: "title too short" } ],
        errors_total_count: 2, warnings: [ { id: "BEV-001", message: "no gtin" } ]
      ))

      described_class.perform_now(run.id)

      expect(run.reload).to have_attributes(status: "partially_failed", error_message: "1 of 3 item(s) rejected by Meta")
      expect(run.result["item_errors"]).to eq("DES-003" => [ "price is missing", "title too short" ])
      expect(run.result).to include("synced_count" => 2, "failed_count" => 1, "warnings_count" => 1)
      rejected = Product.find_by(sku: "DES-003")
      expect(rejected.catalog_sync_error).to eq("price is missing; title too short")
      expect(rejected.catalog_synced_digest).to be_nil
      expect(Product.catalog_dirty).to contain_exactly(rejected)
    end

    it "uses ids_of_invalid_requests when there is no error list" do
      stub_status(entry(ids_of_invalid_requests: [ "MAI-006" ], errors_total_count: 1))

      described_class.perform_now(run.id)

      expect(run.reload.status).to eq("partially_failed")
      expect(Product.catalog_dirty).to contain_exactly(Product.find_by(sku: "MAI-006"))
    end

    it "fails the run when every item was rejected" do
      stub_status(entry(ids_of_invalid_requests: digests.keys, errors_total_count: 3))
      described_class.perform_now(run.id)
      expect(run.reload.status).to eq("failed")
      expect(Product.catalog_dirty.count).to eq(3)
    end

    it "does not mark anything synced when errors cannot be attributed to a product" do
      stub_status(entry(errors: [ { message: "something broke" } ], errors_total_count: 1))

      described_class.perform_now(run.id)

      expect(run.reload.status).to eq("failed")
      expect(run.error_message).to include("could not be attributed")
      expect(Product.catalog_dirty.count).to eq(3)
      expect(Product.where.not(catalog_synced_digest: nil)).to be_empty
    end

    it "does not mark anything synced when Meta reports more errors than it lists, without ids" do
      stub_status(entry(errors: [ { id: "DES-003", message: "bad" } ], errors_total_count: 5))
      described_class.perform_now(run.id)
      expect(run.reload.status).to eq("failed")
      expect(Product.where.not(catalog_synced_digest: nil)).to be_empty
    end

    it "keeps an item rejected at submit time unsynced even if the status entry is clean" do
      run.update!(result: run.result.merge("item_errors" => { "BEV-001" => [ "image_link is invalid" ] }))
      stub_status(entry)

      described_class.perform_now(run.id)

      expect(run.reload.status).to eq("partially_failed")
      expect(Product.catalog_dirty).to contain_exactly(Product.find_by(sku: "BEV-001"))
    end

    it "is a no-op for a run that was already settled" do
      stub_status(entry)
      described_class.perform_now(run.id)
      Product.update_all(catalog_synced_at: nil)
      described_class.perform_now(run.id)
      expect(Product.where.not(catalog_synced_at: nil)).to be_empty
    end
  end

  describe "a batch that is not finished" do
    %w[in_progress started queued].each do |status|
      it "re-polls a #{status} batch after 10s and leaves the run submitted" do
        stub_status(json_response({ data: [ { handle: "H1", status: status } ] }))

        freeze_time do
          expect { described_class.perform_now(run.id) }
            .to have_enqueued_job(described_class).with(run.id, attempt: 2).at(10.seconds.from_now)
        end
        expect(run.reload.status).to eq("submitted")
        expect(Product.catalog_dirty.count).to eq(3)
      end
    end

    it "treats a missing status entry as not finished" do
      stub_status(json_response({ data: [] }))
      expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id, attempt: 2)
    end

    it "backs off 10s, 30s, 1m, 2m, then 5m" do
      stub_status(json_response({ data: [ { status: "in_progress" } ] }))
      waits = (1..7).map do |attempt|
        freeze_time do
          described_class.perform_now(run.id, attempt: attempt)
          job = enqueued_jobs.last
          (Time.zone.parse(job["scheduled_at"]) - Time.current).round
        end
      end
      expect(waits).to eq([ 10, 30, 60, 120, 300, 300, 300 ])
    end

    it "gives up on the 8th poll: the run fails and its products stay dirty" do
      stub_status(json_response({ data: [ { status: "in_progress" } ] }))

      expect { described_class.perform_now(run.id, attempt: 8) }.not_to have_enqueued_job(described_class)

      expect(run.reload.status).to eq("failed")
      expect(run.error_message).to start_with("timed out waiting for Meta")
      expect(run.finished_at).to be_present
      expect(Product.catalog_dirty.count).to eq(3)
      expect(Product.pluck(:catalog_sync_error)).to all(start_with("timed out waiting for Meta"))
    end

    it "keeps polling through a transient HTTP error" do
      stub_status([ 500, {}, "oops" ])
      expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id, attempt: 2)
      expect(run.reload.status).to eq("submitted")
    end

    it "fails at once on an error waiting cannot fix" do
      stub_status(api_error(code: 190, message: "token expired", status: 401))
      expect { described_class.perform_now(run.id) }.not_to have_enqueued_job(described_class)
      expect(run.reload).to have_attributes(status: "failed", error_message: "auth: token expired")
    end
  end

  it "ignores runs that are not submitted push runs" do
    stub_catalog_http { |_s| } # any request would raise
    run.update!(status: "queued")
    expect { described_class.perform_now(run.id) }.not_to have_enqueued_job(described_class)
    expect { described_class.perform_now(0) }.not_to raise_error
  end
end
