# One row per authenticated POST from Meta, stored before anything is
# interpreted. See docs/v2/DESIGN.md §2 and §3.
class WebhookDelivery < ApplicationRecord
  enum :status, {
    received: 0,
    processing: 1,
    processed: 2,
    partially_failed: 3,
    failed: 4,
    ignored: 5,
    unparseable: 6
  }

  validates :raw_body, :body_sha256, :received_at, presence: true
end
