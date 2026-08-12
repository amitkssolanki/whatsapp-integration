class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.integer :direction, null: false
      t.string :wa_message_id
      t.string :message_type, null: false
      t.text :body
      t.jsonb :raw_payload, null: false, default: {}

      t.timestamps
    end
  end
end
