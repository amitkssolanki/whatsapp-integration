class Product < ApplicationRecord
  belongs_to :category
  has_many :order_items, dependent: :nullify

  # Values match Meta's catalog feed `availability` field verbatim.
  enum :availability, {
    in_stock: 0,
    out_of_stock: 1,
    preorder: 2
  }, default: :in_stock

  validates :name, :sku, :price_cents, presence: true
  validates :sku, uniqueness: true
  validates :price_cents, numericality: { greater_than: 0 }

  def price
    price_cents / 100.0
  end

  def formatted_price
    format("$%.2f", price)
  end
end
