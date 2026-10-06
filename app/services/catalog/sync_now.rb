module Catalog
  # The operator's "Sync now" button: enqueue a push immediately (no debounce).
  #
  #   Catalog::SyncNow.call(by: "admin")             # push dirty products
  #   Catalog::SyncNow.call(by: "admin", full: true) # re-send every product
  #
  # Returns a Result; `enqueued` is false (with a reason) when catalog sync is
  # switched off, so the UI can say why nothing happened.
  class SyncNow
    Result = Struct.new(:enqueued, :reason, keyword_init: true) do
      def enqueued? = enqueued
    end

    def self.call(by:, full: false)
      unless Rails.application.config.whatsapp.catalog_sync_enabled
        return Result.new(enqueued: false, reason: "catalog sync is disabled (CATALOG_SYNC_ENABLED)")
      end

      CatalogPushJob.perform_later(full: full, triggered_by: by.to_s.presence || "operator")
      Result.new(enqueued: true)
    end
  end
end
