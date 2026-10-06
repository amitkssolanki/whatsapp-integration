class Order < ApplicationRecord
  include StatusTransitions

  belongs_to :customer
  belongs_to :source_message, class_name: "Message", optional: true # nil only for legacy V1 rows
  has_many :order_items, dependent: :destroy
  has_many :messages, dependent: :nullify

  # V1 called `accepted` "confirmed"; the integer values did not change.
  enum :status, { received: 0, accepted: 1, rejected: 2 }, default: :received

  # An independent flag: an order can need review and still be accepted.
  enum :review_status, { clear: 0, needs_review: 1 }, default: :clear

  ALLOWED_TRANSITIONS = {
    "received" => %w[accepted rejected]
  }.freeze

  validates :total_cents, numericality: { greater_than_or_equal_to: 0 }

  # Operator decisions (docs/v2/DESIGN.md §3, §4). Each one moves the order and
  # queues the customer's notification in one transaction; the notification's
  # idempotency key makes a double click (or two operators) a harmless no-op.
  # Both return an ActionResult; a refusal is never an exception.
  def accept!(by:)
    decide!(:accepted, by: by, rejection_reason: nil) { Conversations::Responder.new.order_accepted(order: self) }
  end

  def reject!(by:, reason:)
    return ActionResult.refused("a reason is required") if reason.blank?

    decide!(:rejected, by: by, rejection_reason: reason.to_s.strip) { Conversations::Responder.new.order_rejected(order: self) }
  end

  def total
    total_cents / 100.0
  end

  def formatted_total
    format("$%.2f", total)
  end

  private

  def decide!(to, by:, **attrs)
    raise ArgumentError, "by: is required" if by.blank?
    return ActionResult.refused("the customer's data was purged; there is no one to notify") if customer.purged?

    queued = nil
    moved = transaction do
      transition!(to, decided_at: Time.current, decided_by: by, **attrs).tap do |ok|
        next unless ok

        conversation = customer.conversation || customer.create_conversation!
        queued = Messages::Outbox.queue(conversation: conversation, reply: yield, order_id: id)
      end
    end

    return ActionResult.refused("order is already #{status}") unless moved

    AppLog.event("order.#{to}", order_id: id, by: by, notification_message_id: queued)
    ActionResult.ok
  end
end
