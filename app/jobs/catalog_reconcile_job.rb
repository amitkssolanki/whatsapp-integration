# Read-only drift check: reads the whole Meta catalog back and records how it
# differs from our products as a CatalogSyncRun (kind "reconcile") whose result
# is {"drift" => [...], "checked" => n, ...}.
#
# It NEVER corrects anything: no push is enqueued, no product is touched. The
# database is the source of truth, but a human decides what a difference means
# (a hand edit in Commerce Manager, a review rejection, a stale feed).
#
# The scheduled run (config/recurring.yml) does nothing unless catalog sync is
# enabled; an operator-triggered run (by: "admin") always runs.
class CatalogReconcileJob < ApplicationJob
  queue_as :default

  def perform(by: "schedule")
    if by == "schedule" && !Rails.application.config.whatsapp.catalog_sync_enabled
      AppLog.event("catalog.reconcile_skipped", reason: "sync_disabled")
      return
    end

    run = CatalogSyncRun.create!(kind: "reconcile", status: "queued", triggered_by: by, started_at: Time.current)
    response = Catalog::Client.new.products
    return fail_run(run, response) unless response.ok?

    remote = response.data.select { |item| item.is_a?(Hash) }
    reconciler = Catalog::Reconciler.new(
      products: Product.non_synthetic.to_a, remote_items: remote, pending_skus: Product.catalog_dirty.pluck(:sku)
    )
    drift = reconciler.drift
    run.finish("succeeded", result: { drift: drift, checked: reconciler.checked, remote_count: remote.size })
    AppLog.event("catalog.reconciled", run_id: run.id, drift: drift.size, checked: reconciler.checked)
  end

  private

  def fail_run(run, response)
    run.finish("failed", error_message: "#{response.category}: #{response.error_message}".truncate(500))
    AppLog.event("catalog.reconcile_failed", run_id: run.id, category: response.category)
  end
end
