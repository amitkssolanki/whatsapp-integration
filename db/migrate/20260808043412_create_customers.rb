class CreateCustomers < ActiveRecord::Migration[8.1]
  def change
    create_table :customers do |t|
      t.string :whatsapp_number, null: false
      t.string :display_name
      t.boolean :opted_in, null: false, default: true

      t.timestamps
    end
    add_index :customers, :whatsapp_number, unique: true
  end
end
