class ExtendOrdersAndSupportingTables < ActiveRecord::Migration[8.1]
  def change
    # Order#status keeps its integer values: received 0, accepted 1 (V1 called
    # it "confirmed"), rejected 2. No data change is needed.
    change_table :orders, bulk: true do |t|
      t.references :source_message, foreign_key: { to_table: :messages }, index: { unique: true }
      t.integer :review_status, null: false, default: 0
      t.jsonb :validation_issues, null: false, default: []
      t.datetime :decided_at
      t.string :decided_by
      t.text :rejection_reason
    end

    add_column :order_items, :catalog_price_cents, :integer
    add_column :conversations, :last_inbound_at, :datetime
    add_column :customers, :wa_user_id, :string

    change_table :products, bulk: true do |t|
      t.string :catalog_synced_digest
      t.datetime :catalog_synced_at
      t.text :catalog_sync_error
    end

    create_table :catalog_sync_runs do |t|
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.string :batch_handle
      t.jsonb :requested_items, null: false, default: []
      t.jsonb :result, null: false, default: {}
      t.string :triggered_by
      t.datetime :started_at
      t.datetime :finished_at
      t.text :error_message

      t.timestamps
    end
  end
end
