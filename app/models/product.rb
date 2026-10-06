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

  # Products whose current Meta-facing fields differ from what was last
  # confirmed pushed (or that were never pushed). The digest is computed in
  # Ruby, so this scans the table; fine for a restaurant menu.
  scope :catalog_dirty, -> { where(id: unscoped.select(&:catalog_dirty?).map(&:id)) }

  # Debounced push: wait CatalogPushJob::DEBOUNCE, then the job sends every
  # dirty product at once. Duplicate enqueues from a burst of edits are fine
  # because the job is idempotent by digest. Deleting a product does not delete
  # it from Meta (docs/v2/CATALOG.md): mark it out of stock instead.
  after_commit :enqueue_catalog_push, on: [ :create, :update ]

  def catalog_fields
    Catalog::Fields.for(self)
  end

  # SHA256 of the canonical JSON of catalog_fields.
  def catalog_digest
    Catalog::Fields.digest(catalog_fields)
  end

  def catalog_dirty?
    catalog_synced_digest != catalog_digest
  end

  def price
    price_cents / 100.0
  end

  def formatted_price
    format("$%.2f", price)
  end

  private

  def enqueue_catalog_push
    return unless Rails.application.config.whatsapp.catalog_sync_enabled
    return if (saved_changes.keys & Catalog::Fields::PRODUCT_ATTRIBUTES).empty?

    CatalogPushJob.set(wait: CatalogPushJob::DEBOUNCE).perform_later
  end
end
