require "rails_helper"

RSpec.describe Catalog::Status do
  it "is empty before anything has happened" do
    status = described_class.call
    expect(status).to have_attributes(
      last_push_run: nil, last_reconcile_run: nil, dirty_count: 0, drift_count: 0, failing_products: []
    )
  end

  it "summarizes runs, dirty products, drift and failing products" do
    products = create_menu
    products.first.update_columns(catalog_synced_digest: products.first.catalog_digest)
    products.last.update_columns(catalog_sync_error: "image_link is invalid")

    old_push = CatalogSyncRun.create!(kind: "push", status: "failed", created_at: 2.hours.ago)
    new_push = CatalogSyncRun.create!(kind: "push", status: "submitted", created_at: 1.hour.ago)
    old_reconcile = CatalogSyncRun.create!(kind: "reconcile", status: "succeeded", created_at: 3.days.ago,
                                           result: { drift: [ { type: "missing_remote", sku: "X" } ] })
    new_reconcile = CatalogSyncRun.create!(
      kind: "reconcile", status: "succeeded", created_at: 1.day.ago,
      result: { drift: [
        { type: "price_mismatch", sku: "A" }, { type: "extra_remote", sku: "B" },
        { type: "price_mismatch", sku: "C", pending_push: true }
      ] }
    )

    status = described_class.call

    expect(status.last_push_run).to eq(new_push)
    expect(status.last_reconcile_run).to eq(new_reconcile)
    expect([ old_push, old_reconcile ]).not_to include(status.last_push_run, status.last_reconcile_run)
    expect(status.dirty_count).to eq(2)
    expect(status.drift_count).to eq(2) # pending_push drift is expected, not counted
    expect(status.failing_products).to eq([ products.last ])
    expect(status.to_h.keys).to eq(%i[last_push_run last_reconcile_run dirty_count drift_count failing_products])
  end

  it "takes drift from the last successful reconcile, not a failed one" do
    CatalogSyncRun.create!(kind: "reconcile", status: "succeeded", created_at: 2.days.ago,
                           result: { drift: [ { type: "missing_remote", sku: "X" } ] })
    failed = CatalogSyncRun.create!(kind: "reconcile", status: "failed", created_at: 1.day.ago, error_message: "auth: expired")

    status = described_class.call

    expect(status.last_reconcile_run).to eq(failed)
    expect(status.drift_count).to eq(1)
  end
end
