module Ops
  # Catalog sync activity in the period, the drift the latest successful
  # reconcile in the period found, and how many products are dirty right now
  # (a current-state figure, not tied to the period).
  class CatalogSection
    DRIFT_TYPES = %w[
      missing_remote extra_remote price_mismatch price_unparseable
      availability_mismatch name_mismatch review_not_approved
    ].freeze

    def initialize(period)
      @runs = CatalogSyncRun.where(created_at: period)
    end

    def call
      {
        push_runs: by_status(@runs.pushes),
        reconcile_runs: by_status(@runs.reconciles),
        last_reconcile: last_reconcile,
        products_dirty: Product.catalog_dirty.count
      }
    end

    private

    def by_status(scope)
      Stats.zero_filled(CatalogSyncRun::STATUSES, scope.group(:status).count)
    end

    # Drift by type from the newest succeeded reconcile run in the period.
    # `pending_push` counts drift expected to clear with the next push.
    def last_reconcile
      run = @runs.reconciles.where(status: "succeeded").order(:created_at, :id).last
      drift = run ? Array(run.result["drift"]).grep(Hash) : []

      {
        found: run.present?,
        drift_total: drift.size,
        drift_pending_push: drift.count { |item| item["pending_push"] },
        drift_by_type: Stats.zero_filled(DRIFT_TYPES, drift.filter_map { |item| item["type"].to_s.presence }.tally)
      }
    end
  end
end
