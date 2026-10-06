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
end
