class ApplicationJob < ActiveJob::Base
  # `perform_later` returns false (it does not raise) when the enqueue fails.
  # Callers that enqueue inside a transaction raise this instead, so the whole
  # transaction rolls back rather than committing work nothing will ever run:
  #
  #   SomeJob.perform_later(id) || raise(ApplicationJob::EnqueueFailed, "SomeJob")
  class EnqueueFailed < StandardError; end

  # Enqueue immediately, inside any open transaction. Solid Queue shares the
  # primary database, so the job row commits or rolls back atomically with the
  # rows that caused it: no "committed but never enqueued" window. This is the
  # Rails 8.1 default; it is pinned here because the design depends on it.
  self.enqueue_after_transaction_commit = false

  # Whatever escapes a job is stored by Solid Queue in solid_queue_failed_executions
  # (`error` = { exception_class, message, backtrace }: solid_queue 1.7.0,
  # app/models/solid_queue/failed_execution.rb) and logged by Active Job. The
  # message of an unexpected database error can echo the row it was about to
  # write, e.g. a RecordNotUnique whose DETAIL names a Meta message id (which
  # embeds a phone number). So the error is re-raised with a scrubbed message
  # (Redact): same class, same backtrace and cause chain, so retry_on and
  # Webhooks::InfrastructureError still recognise it.
  around_perform do |_job, block|
    block.call
  rescue StandardError => error
    scrubbed = Redact.scrub(error.message, limit: SCRUBBED_MESSAGE_LIMIT)
    raise(scrubbed == error.message ? error : error.exception(scrubbed))
  end

  SCRUBBED_MESSAGE_LIMIT = 500
end
