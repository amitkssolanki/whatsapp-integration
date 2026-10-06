class Category < ApplicationRecord
  has_many :products, dependent: :restrict_with_error
  # What the public menu shows: synthetic (demo) products are never listed.
  has_many :menu_products, -> { non_synthetic }, class_name: "Product", inverse_of: :category

  # Categories that hold nothing but synthetic products stay off the public menu too.
  scope :on_menu, -> {
    synthetic_only = unscoped.joins(:products).group("categories.id").having("BOOL_AND(products.synthetic)").select("categories.id")
    where.not(id: synthetic_only)
  }

  validates :name, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true

  default_scope { order(:position, :name) }
end
