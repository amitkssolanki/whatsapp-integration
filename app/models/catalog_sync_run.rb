# One attempt to push product changes to the WhatsApp Catalog, or one read-only
# reconcile pass (docs/v2/DESIGN.md §2, docs/v2/CATALOG.md).
#
# push:      queued -> submitted -> succeeded | partially_failed | failed
# reconcile: succeeded | failed
#
# For a push, `requested_items` is {sku => digest sent}: the digest is what gets
# stored on the product when Meta confirms the batch, so a product edited
# while the batch was in flight stays dirty. `result` holds handles, per-item
# errors and counters; `batch_handle` is the first handle.
class CatalogSyncRun < ApplicationRecord
  KINDS = %w[push reconcile].freeze
  STATUSES = %w[queued submitted succeeded partially_failed failed].freeze
  IN_FLIGHT = %w[queued submitted].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }

  scope :pushes, -> { where(kind: "push") }
  scope :reconciles, -> { where(kind: "reconcile") }
  scope :in_flight, -> { where(status: IN_FLIGHT) }

  def in_flight?
    IN_FLIGHT.include?(status)
  end

  # {sku => digest} regardless of how the jsonb column was written.
  def requested_digests
    requested_items.is_a?(Hash) ? requested_items : {}
  end

  def handles
    Array(result["handles"]).presence || Array(batch_handle.presence)
  end

  # Moves an in-flight run to a final status. The conditional UPDATE means a
  # duplicate job that loses the race changes nothing. Returns true if this
  # call made the transition.
  def finish(status, error_message: nil, result: {})
    merged = self.result.merge(result.deep_stringify_keys)
    now = Time.current
    updated = self.class.in_flight.where(id: id).update_all(
      status: status, error_message: error_message, result: merged, finished_at: now, updated_at: now
    )
    reload
    updated == 1
  end
end
