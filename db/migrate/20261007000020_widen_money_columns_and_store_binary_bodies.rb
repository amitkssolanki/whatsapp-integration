# Two robustness fixes found in review.
#
# 1. Order totals are sums of price x quantity in cents. A hostile (or just
#    absurd) cart overflows int4 (about 21 million in major units), which would
#    fail the whole item. The money columns an order is computed from become
#    bigint.
#
# 2. webhook_deliveries.raw_body is text, and PostgreSQL text cannot hold NUL
#    bytes or invalid UTF-8. Such a body used to be scrubbed before storing,
#    which destroyed the bytes the signature was computed over. The exact bytes
#    now go in raw_body_base64 (only for those bodies; raw_body keeps a scrubbed
#    copy for display), so the delivery stays verifiable.
class WidenMoneyColumnsAndStoreBinaryBodies < ActiveRecord::Migration[8.1]
  def up
    change_column :orders, :total_cents, :bigint, default: 0, null: false
    change_column :order_items, :item_price_cents, :bigint, default: 0, null: false
    change_column :order_items, :catalog_price_cents, :bigint

    add_column :webhook_deliveries, :raw_body_base64, :text
  end

  def down
    remove_column :webhook_deliveries, :raw_body_base64

    change_column :order_items, :catalog_price_cents, :integer
    change_column :order_items, :item_price_cents, :integer, default: 0, null: false
    change_column :orders, :total_cents, :integer, default: 0, null: false
  end
end
