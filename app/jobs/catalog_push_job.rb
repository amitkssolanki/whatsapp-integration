# Sends changed products to the Meta catalog in one items_batch call and hands
# the batch handle to CatalogBatchStatusJob, which confirms the outcome.
#
#   CatalogPushJob.perform_later                    # all dirty products
#   CatalogPushJob.perform_later(full: true)        # every product, dirty or not
#   CatalogPushJob.perform_later(run_id)            # internal: retry a run
#
# Idempotent by digest: it pushes only products whose digest differs from the
# last confirmed one (and are not already in an in-flight batch with the same
# digest), so duplicate enqueues from rapid edits do nothing extra. Nothing is
# marked synced here; only a finished batch status does that.
#
# A push that fails with a retryable category (timeout, 5xx, rate limit) is
# retried on the same run, 3 attempts in all; then the run is failed and shows
# up in Catalog::Status. Failed runs leave their products dirty.
class CatalogPushJob < ApplicationJob
  queue_as :default

  MAX_BATCH = 5000
  MAX_PUSH_ATTEMPTS = 3
  RETRY_WAITS = [ 1.minute, 5.minutes ].freeze
  STATUS_POLL_DELAY = 10.seconds
  DEBOUNCE = 30.seconds # delay for pushes triggered by product edits
  IN_FLIGHT_WINDOW = 1.hour # ignore runs older than this when de-duplicating

  def perform(run_id = nil, full: false, triggered_by: "product_change")
    unless Rails.application.config.whatsapp.catalog_sync_enabled
      AppLog.event("catalog.push_skipped", reason: "sync_disabled")
      return
    end

    run_id ? retry_run(CatalogSyncRun.find_by(id: run_id)) : start_run(full: full, triggered_by: triggered_by)
  end

  private

  def start_run(full:, triggered_by:)
    products = candidates(full)
    return AppLog.event("catalog.push_skipped", reason: "nothing_dirty") if products.empty?

    truncated = products.size > MAX_BATCH
    products = products.first(MAX_BATCH)
    payload = build_payload(products)

    run = CatalogSyncRun.create!(
      kind: "push", status: "queued", triggered_by: triggered_by, started_at: Time.current,
      requested_items: payload[:digests], result: { "push_attempts" => 0 }
    )
    # Whatever did not fit stays dirty; another pass picks it up.
    CatalogPushJob.perform_later(triggered_by: triggered_by) if truncated
    submit(run, payload[:requests])
  end

  # Re-sends a queued run after a retryable failure. The current product state
  # is re-read, and requested_items updated, so the digest recorded as "sent"
  # is always the one in the request that Meta accepts.
  def retry_run(run)
    return unless run && run.kind == "push" && run.status == "queued"

    products = Product.where(sku: run.requested_digests.keys).order(:sku).to_a
    return run.finish("failed", error_message: "no products left to push") if products.empty?

    payload = build_payload(products)
    run.update!(requested_items: payload[:digests])
    submit(run, payload[:requests])
  end

  def candidates(full)
    products = full ? Product.order(:sku).to_a : Product.catalog_dirty.order(:sku).to_a
    return products if full

    in_flight = in_flight_digests
    products.reject { |product| in_flight[product.sku] == product.catalog_digest }
  end

  def in_flight_digests
    CatalogSyncRun.pushes.in_flight.where(created_at: IN_FLIGHT_WINDOW.ago..).pluck(:requested_items).each_with_object({}) do |items, digests|
      digests.merge!(items) if items.is_a?(Hash)
    end
  end

  # Fields and digest come from the same read of each product, so the digest
  # we later record as synced is exactly what was sent.
  def build_payload(products)
    requests = []
    digests = {}
    products.each do |product|
      fields = product.catalog_fields
      requests << { method: "UPDATE", data: fields }
      digests[product.sku] = Catalog::Fields.digest(fields)
    end
    { requests: requests, digests: digests }
  end

  def submit(run, requests)
    attempts = run.result["push_attempts"].to_i + 1
    response = Catalog::Client.new.items_batch(requests)
    return handle_failure(run, response, attempts) unless response.ok?

    handles = Array(response.data["handles"]).select(&:present?)
    if handles.empty?
      return fail_run(run, "empty_handles: Meta accepted the batch but returned no handle", attempts)
    end

    report = Catalog::BatchReport.new(run.requested_digests.keys).absorb_validation_status(response.data["validation_status"])
    run.update!(
      status: "submitted", batch_handle: handles.first, error_message: nil,
      result: run.result.merge("push_attempts" => attempts, "handles" => handles).merge(report.to_result)
    )
    record_item_errors(report.item_errors)
    AppLog.event("catalog.push_submitted", run_id: run.id, items: run.requested_digests.size, attempts: attempts)
    CatalogBatchStatusJob.set(wait: STATUS_POLL_DELAY).perform_later(run.id)
  end

  def handle_failure(run, response, attempts)
    message = "#{response.category}: #{response.error_message}".truncate(500)
    if response.retryable? && attempts < MAX_PUSH_ATTEMPTS
      run.update!(error_message: message, result: run.result.merge("push_attempts" => attempts))
      AppLog.event("catalog.push_retry", run_id: run.id, attempts: attempts, category: response.category)
      CatalogPushJob.set(wait: RETRY_WAITS.fetch(attempts - 1)).perform_later(run.id)
    else
      fail_run(run, message, attempts)
    end
  end

  def fail_run(run, message, attempts)
    run.finish("failed", error_message: message, result: { "push_attempts" => attempts })
    Product.where(sku: run.requested_digests.keys).update_all(catalog_sync_error: message)
    AppLog.event("catalog.push_failed", run_id: run.id, attempts: attempts)
  end

  def record_item_errors(item_errors)
    item_errors.each do |sku, messages|
      Product.where(sku: sku).update_all(catalog_sync_error: messages.join("; ").truncate(1000))
    end
  end
end
