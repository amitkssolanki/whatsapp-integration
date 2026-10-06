class Conversation < ApplicationRecord
  # WhatsApp lets a business send free-form messages for 24 hours after the
  # customer's last message. We stop 5 minutes early so clock skew and queue
  # delay never push a send over the edge (docs/v2/DESIGN.md §8). The only
  # place these numbers live.
  WINDOW = 24.hours
  WINDOW_SAFETY_MARGIN = 5.minutes

  belongs_to :customer
  has_many :messages, dependent: :destroy

  # nil when the customer has never written to us: nothing may be sent.
  def window_closes_at
    last_inbound_at && last_inbound_at + WINDOW - WINDOW_SAFETY_MARGIN
  end

  def window_open?(at: Time.current)
    closes_at = window_closes_at
    closes_at.present? && at < closes_at
  end
end
