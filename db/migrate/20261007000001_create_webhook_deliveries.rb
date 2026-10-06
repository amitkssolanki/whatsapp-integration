class CreateWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_deliveries do |t|
      t.text :raw_body, null: false
      t.string :body_sha256, limit: 64, null: false
      t.string :signature_header
      t.string :request_id
      t.string :object_type
      t.string :phone_number_id
      t.jsonb :item_counts, null: false, default: {}
      t.integer :status, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.jsonb :outcome, null: false, default: {}
      t.string :last_error_class
      t.text :last_error_message
      t.datetime :received_at, null: false
      t.datetime :last_attempted_at
      t.datetime :processed_at
      t.integer :replay_count, null: false, default: 0
      t.datetime :last_replayed_at
      t.string :last_replayed_by

      t.timestamps
    end

    add_index :webhook_deliveries, [ :status, :received_at ]
    add_index :webhook_deliveries, :body_sha256
    add_index :webhook_deliveries, :received_at
  end
end
