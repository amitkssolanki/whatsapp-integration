module Catalog
  # Read-only summary of catalog sync for the operator UI.
  #
  #   status = Catalog::Status.call
  #   status.last_push_run       # most recent CatalogSyncRun(kind: "push") or nil
  #   status.last_reconcile_run  # most recent CatalogSyncRun(kind: "reconcile") or nil
  #   status.dirty_count         # products whose current fields are not confirmed pushed
  #   status.drift_count         # drift items in the last successful reconcile, not counting
  #                              # products with an unconfirmed local change (pending_push)
  #   status.failing_products    # products with a catalog_sync_error (array, ordered by sku)
  #
  # The result also answers #to_h and #[] with the same keys.
  class Status
    Snapshot = Struct.new(:last_push_run, :last_reconcile_run, :dirty_count, :drift_count, :failing_products, keyword_init: true)

    def self.call
      last_reconcile = CatalogSyncRun.reconciles.order(:created_at, :id).last
      Snapshot.new(
        last_push_run: CatalogSyncRun.pushes.order(:created_at, :id).last,
        last_reconcile_run: last_reconcile,
        dirty_count: Product.catalog_dirty.count,
        drift_count: drift_count(CatalogSyncRun.reconciles.where(status: "succeeded").order(:created_at, :id).last),
        failing_products: Product.where.not(catalog_sync_error: [ nil, "" ]).order(:sku).to_a
      )
    end

    def self.drift_count(run)
      return 0 unless run

      Array(run.result["drift"]).count { |item| !item["pending_push"] }
    end
    private_class_method :drift_count
  end
end
