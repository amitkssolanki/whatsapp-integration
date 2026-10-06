class ApplicationJob < ActiveJob::Base
  # Enqueue immediately, inside any open transaction. Solid Queue shares the
  # primary database, so the job row commits or rolls back atomically with the
  # rows that caused it: no "committed but never enqueued" window. This is the
  # Rails 8.1 default; it is pinned here because the design depends on it.
  self.enqueue_after_transaction_commit = false
end
