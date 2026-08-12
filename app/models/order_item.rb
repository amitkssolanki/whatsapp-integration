class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product, optional: true # webhook retailer_id may not match a seeded product

  validates :product_retailer_id, presence: true
  validates :quantity, numericality: { greater_than: 0 }

  def item_price
    item_price_cents / 100.0
  end

  def line_total_cents
    item_price_cents * quantity
  end
end
