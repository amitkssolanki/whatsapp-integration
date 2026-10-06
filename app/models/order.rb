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

  # Legacy V1 builder, replaced by Orders::Builder with the new webhook pipeline.
  def self.create_from_whatsapp!(customer:, catalog_id:, note:, product_items:)
    transaction do
      order = create!(customer: customer, catalog_id: catalog_id, wa_order_note: note, total_cents: 0)

      total = 0
      product_items.each do |item|
        retailer_id = item["product_retailer_id"]
        quantity = item["quantity"].to_i
        # WhatsApp sends item_price as a decimal string in the catalog's currency.
        unit_price_cents = (item["item_price"].to_f * 100).round
        total += unit_price_cents * quantity

        order.order_items.create!(
          product: Product.find_by(sku: retailer_id),
          product_retailer_id: retailer_id,
          quantity: quantity,
          item_price_cents: unit_price_cents,
          currency: item["currency"] || "USD"
        )
      end

      order.update!(total_cents: total)
      order
    end
  end
end
