class CreateOrderItems < ActiveRecord::Migration[8.1]
  def change
    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: true
      t.references :product, null: true, foreign_key: true
      t.string :product_retailer_id, null: false
      t.integer :quantity, null: false, default: 1
      t.integer :item_price_cents, null: false, default: 0
      t.string :currency, null: false, default: "USD"

      t.timestamps
    end
  end
end
