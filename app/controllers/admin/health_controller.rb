module Admin
  # The landing page: everything that needs an operator, in one read-only query
  # pass (Health::Snapshot, Catalog::Status). Its buttons POST to other controllers.
  class HealthController < BaseController
    DRIFT_LIMIT = 20

    def show
      @snapshot = Health::Snapshot.new.call
      @catalog = Catalog::Status.call
      @catalog_enabled = Rails.application.config.whatsapp.catalog_sync_enabled
      drift_run = CatalogSyncRun.reconciles.where(status: "succeeded").order(:created_at, :id).last
      all_drift = Array(drift_run&.result&.dig("drift"))
      @pending_drift = all_drift.count { |item| item["pending_push"] }
      @drift = all_drift.reject { |item| item["pending_push"] }.first(DRIFT_LIMIT)
    end
  end
end
