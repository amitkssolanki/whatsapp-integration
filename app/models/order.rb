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

  def total
    total_cents / 100.0
  end

  def formatted_total
    format("$%.2f", total)
  end
end
