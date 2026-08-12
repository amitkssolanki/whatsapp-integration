class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :customer, null: false, foreign_key: true
      t.text :wa_order_note
      t.integer :status, null: false, default: 0
      t.integer :total_cents, null: false, default: 0
      t.string :currency, null: false, default: "USD"
      t.string :catalog_id

      t.timestamps
    end
  end
end
