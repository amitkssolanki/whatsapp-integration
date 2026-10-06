# Polls Meta for the outcome of a submitted catalog batch (a 200 from
# items_batch only means "queued") and settles the run.
#
# Only a `finished` status counts. Anything else is re-polled with backoff
# (10s, 30s, 1m, 2m, then 5m) for up to 8 polls, after which the run is failed
# with "timed out waiting for Meta".
#
# On finish, each product Meta did not reject gets catalog_synced_digest = the
# digest that was SENT (run.requested_items), not its current one, so a product
# edited while the batch was in flight stays dirty. A failed run leaves its
# products dirty.
class CatalogBatchStatusJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 8
  BACKOFF = [ 10.seconds, 30.seconds, 1.minute, 2.minutes, 5.minutes ].freeze

  def perform(run_id, attempt: 1)
    run = CatalogSyncRun.find_by(id: run_id)
    return unless run && run.kind == "push" && run.status == "submitted"

    entries = []
    run.handles.each do |handle|
      response = Catalog::Client.new.batch_status(handle)
      unless response.ok?
        # A bad token or missing permission will not fix itself by waiting.
        return fail_run(run, "#{response.category}: #{response.error_message}") unless response.retryable? || response.category == "unclassified"

        return wait_or_give_up(run, attempt, "last poll: #{response.category}")
      end
      return wait_or_give_up(run, attempt, "last status: #{response.data&.dig('status') || 'none'}") unless response.data&.dig("status") == "finished"

      entries << response.data
    end

    settle(run, entries)
  end

  private

  def wait_or_give_up(run, attempt, note)
    if attempt >= MAX_ATTEMPTS
      fail_run(run, "timed out waiting for Meta (#{note})")
    else
      CatalogBatchStatusJob.set(wait: BACKOFF.fetch(attempt - 1, BACKOFF.last)).perform_later(run.id, attempt: attempt + 1)
    end
  end

  def settle(run, entries)
    sent = run.requested_digests
    report = Catalog::BatchReport.new(sent.keys).restore(run.result)
    entries.each { |entry| report.absorb_status_entry(entry) }

    if report.unattributed?
      message = "Meta reported #{report.unattributed_count} error(s) that could not be attributed to a product; none were marked synced"
      return fail_run(run, message, result: report.to_result)
    end

    failed = report.failed_skus
    synced = sent.reject { |sku, _digest| failed.include?(sku) }
    mark_synced(synced)
    failed.each { |sku| Product.where(sku: sku).update_all(catalog_sync_error: report.item_errors[sku].join("; ").truncate(1000)) }

    status = if failed.empty? then "succeeded" elsif synced.empty? then "failed" else "partially_failed" end
    message = failed.empty? ? nil : "#{failed.size} of #{sent.size} item(s) rejected by Meta"
    result = report.to_result.merge("synced_count" => synced.size, "failed_count" => failed.size, "warnings_count" => entries.sum { |e| Array(e["warnings"]).size })
    run.finish(status, error_message: message, result: result)
    AppLog.event("catalog.push_settled", run_id: run.id, status: status, synced: synced.size, failed: failed.size)
  end

  def mark_synced(synced)
    now = Time.current
    synced.each do |sku, digest|
      Product.where(sku: sku).update_all(catalog_synced_digest: digest, catalog_synced_at: now, catalog_sync_error: nil)
    end
  end

  def fail_run(run, message, result: {})
    return unless run.finish("failed", error_message: message, result: result)

    Product.where(sku: run.requested_digests.keys).update_all(catalog_sync_error: message.truncate(1000))
    AppLog.event("catalog.push_failed", run_id: run.id)
  end
end
