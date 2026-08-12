class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.string :name, null: false
      t.text :description
      t.integer :price_cents, null: false
      t.string :currency, null: false, default: "USD"
      t.string :sku, null: false
      t.string :image_url
      t.integer :availability, null: false, default: 0
      t.string :brand
      t.references :category, null: false, foreign_key: true

      t.timestamps
    end
    add_index :products, :sku, unique: true
  end
end
