class Order < ApplicationRecord
  belongs_to :customer
  has_many :order_items, dependent: :destroy

  enum :status, { received: 0, confirmed: 1 }, default: :received

  validates :total_cents, numericality: { greater_than_or_equal_to: 0 }

  default_scope { order(created_at: :desc) }

  def total
    total_cents / 100.0
  end

  def formatted_total
    format("$%.2f", total)
  end

  # Builds and persists an Order + OrderItems from a WhatsApp `order`
  # webhook message. product_items is the raw array from
  # payload["messages"][0]["order"]["product_items"].
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
