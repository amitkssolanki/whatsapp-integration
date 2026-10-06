class ExtendMessagesForDeliveryTracking < ActiveRecord::Migration[8.1]
  INBOUND = 0
  OUTBOUND = 1
  STATUS_RECEIVED = 0
  STATUS_UNKNOWN = 92

  def up
    change_table :messages, bulk: true do |t|
      t.integer :status, null: false, default: STATUS_RECEIVED
      t.string :purpose
      t.string :idempotency_key
      t.references :order, foreign_key: true, index: true
      t.references :webhook_delivery, foreign_key: { on_delete: :nullify }, index: true
      t.datetime :wa_timestamp
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :accepted_at
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :read_at
      t.datetime :failed_at
      t.datetime :blocked_at
      t.integer :error_code
      t.string :error_category
      t.string :error_title
      t.text :error_details
      t.string :guard_override_by
    end

    # V1 never recorded what happened to anything it sent, so the honest status
    # for every historical outbound row is "unknown", not "sent". Inbound rows
    # keep the column default (received).
    execute "UPDATE messages SET status = #{STATUS_UNKNOWN} WHERE direction = #{OUTBOUND}"

    # V1 stored every delivery of a duplicated webhook as its own row. Keep the
    # first one as the owner of the id (the id also stays in raw_payload) so the
    # unique index below can exist on real data.
    execute <<~SQL.squish
      UPDATE messages SET wa_message_id = NULL
      WHERE wa_message_id IS NOT NULL
        AND id NOT IN (SELECT MIN(id) FROM messages WHERE wa_message_id IS NOT NULL GROUP BY wa_message_id)
    SQL

    add_index :messages, :wa_message_id, unique: true, where: "wa_message_id IS NOT NULL",
              name: "index_messages_on_wa_message_id"
    add_index :messages, :idempotency_key, unique: true, where: "idempotency_key IS NOT NULL",
              name: "index_messages_on_idempotency_key"
    add_index :messages, [ :direction, :status, :accepted_at ]
  end

  def down
    remove_index :messages, [ :direction, :status, :accepted_at ]
    remove_index :messages, name: "index_messages_on_idempotency_key"
    remove_index :messages, name: "index_messages_on_wa_message_id"

    change_table :messages, bulk: true do |t|
      t.remove_references :webhook_delivery, foreign_key: true
      t.remove_references :order, foreign_key: true
      t.remove :status, :purpose, :idempotency_key, :wa_timestamp, :attempts, :next_attempt_at,
               :accepted_at, :sent_at, :delivered_at, :read_at, :failed_at, :blocked_at,
               :error_code, :error_category, :error_title, :error_details, :guard_override_by
    end
  end
end
