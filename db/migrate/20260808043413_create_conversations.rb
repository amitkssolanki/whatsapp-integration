class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations do |t|
      t.references :customer, null: false, foreign_key: true, index: { unique: true }
      t.datetime :last_message_at

      t.timestamps
    end
  end
end
