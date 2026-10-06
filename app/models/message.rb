# Inbound and outbound WhatsApp messages share one table so a conversation is a
# single timeline. Outbound rows carry the delivery lifecycle; see
# docs/v2/DESIGN.md §3.
class Message < ApplicationRecord
  belongs_to :conversation
  belongs_to :order, optional: true
  belongs_to :webhook_delivery, optional: true

  enum :direction, { inbound: 0, outbound: 1 }

  # Inbound rows are always `received`; the rest describe an outbound message.
  enum :status, {
    received: 0,
    pending: 10,
    sending: 20,
    retry_scheduled: 25,
    accepted: 30,
    sent: 40,
    delivered: 50,
    read: 60,
    failed: 90,
    blocked: 91,
    unknown: 92
  }

  validates :message_type, presence: true

  scope :chronological, -> { order(:created_at, :id) }
end
