# One row per authenticated POST from Meta, stored before anything is
# interpreted. See docs/v2/DESIGN.md §2 and §3.
class WebhookDelivery < ApplicationRecord
  include StatusTransitions

  enum :status, {
    received: 0,
    processing: 1,
    processed: 2,
    partially_failed: 3,
    failed: 4,
    ignored: 5,
    unparseable: 6
  }

  ALLOWED_TRANSITIONS = {
    "received" => %w[processing],
    "failed" => %w[processing],
    "partially_failed" => %w[processing],
    "processed" => %w[processing],
    "processing" => %w[processed partially_failed failed ignored]
  }.freeze

  REPLAYABLE_STATUSES = %w[failed partially_failed processed].freeze

  validates :raw_body, :body_sha256, :received_at, presence: true

  def replayable?
    REPLAYABLE_STATUSES.include?(status)
  end
end
