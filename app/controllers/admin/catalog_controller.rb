module Admin
  # Operator buttons for catalog sync. Both only enqueue a job; Meta is never
  # called from the request.
  class CatalogController < BaseController
    def sync_now
      result = Catalog::SyncNow.call(by: current_operator)
      if result.enqueued?
        redirect_to admin_health_path, notice: "Catalog push queued. Only products with unsynced changes are sent."
      else
        redirect_to admin_health_path, alert: "Not done: #{result.reason}"
      end
    end

    # Read-only drift check. It never corrects anything on Meta or here.
    def reconcile_now
      if CatalogReconcileJob.perform_later(by: current_operator)
        redirect_to admin_health_path, notice: "Catalog reconcile queued. It only reads; nothing is changed."
      else
        redirect_to admin_health_path, alert: "Not done: the reconcile job could not be queued"
      end
    end
  end
end
