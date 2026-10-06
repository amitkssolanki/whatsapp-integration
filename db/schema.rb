# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_07_000024) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "catalog_sync_runs", force: :cascade do |t|
    t.string "kind", null: false
    t.string "status", default: "pending", null: false
    t.string "batch_handle"
    t.jsonb "requested_items", default: [], null: false
    t.jsonb "result", default: {}, null: false
    t.string "triggered_by"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "categories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_categories_on_name", unique: true
    t.index ["slug"], name: "index_categories_on_slug", unique: true
  end

  create_table "conversations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "customer_id", null: false
    t.datetime "last_message_at"
    t.datetime "updated_at", null: false
    t.datetime "last_inbound_at"
    t.index ["customer_id"], name: "index_conversations_on_customer_id", unique: true
  end

  create_table "customers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name"
    t.boolean "opted_in", default: true, null: false
    t.datetime "updated_at", null: false
    t.string "whatsapp_number"
    t.string "wa_user_id"
    t.index ["wa_user_id"], name: "index_customers_on_wa_user_id", unique: true, where: "(wa_user_id IS NOT NULL)"
    t.index ["whatsapp_number"], name: "index_customers_on_whatsapp_number", unique: true, where: "(whatsapp_number IS NOT NULL)"
    t.check_constraint "whatsapp_number IS NOT NULL OR wa_user_id IS NOT NULL", name: "customers_identity_present"
  end

  create_table "messages", force: :cascade do |t|
    t.text "body"
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.integer "direction", null: false
    t.string "message_type", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "updated_at", null: false
    t.string "wa_message_id"
    t.integer "status", default: 0, null: false
    t.string "purpose"
    t.string "idempotency_key"
    t.bigint "order_id"
    t.bigint "webhook_delivery_id"
    t.datetime "wa_timestamp"
    t.integer "attempts", default: 0, null: false
    t.datetime "next_attempt_at"
    t.datetime "accepted_at"
    t.datetime "sent_at"
    t.datetime "delivered_at"
    t.datetime "read_at"
    t.datetime "failed_at"
    t.datetime "blocked_at"
    t.integer "error_code"
    t.string "error_category"
    t.string "error_title"
    t.text "error_details"
    t.string "guard_override_by"
    t.datetime "unknown_at"
    t.string "injected_faults", default: [], null: false, array: true
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["direction", "status", "accepted_at"], name: "index_messages_on_direction_and_status_and_accepted_at"
    t.index ["idempotency_key"], name: "index_messages_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["order_id"], name: "index_messages_on_order_id"
    t.index ["wa_message_id"], name: "index_messages_on_wa_message_id", unique: true, where: "(wa_message_id IS NOT NULL)"
    t.index ["webhook_delivery_id"], name: "index_messages_on_webhook_delivery_id"
  end

  create_table "order_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.bigint "item_price_cents", default: 0, null: false
    t.bigint "order_id", null: false
    t.bigint "product_id"
    t.string "product_retailer_id", null: false
    t.integer "quantity", default: 1, null: false
    t.datetime "updated_at", null: false
    t.bigint "catalog_price_cents"
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_id"], name: "index_order_items_on_product_id"
  end

  create_table "orders", force: :cascade do |t|
    t.string "catalog_id"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.bigint "customer_id", null: false
    t.integer "status", default: 0, null: false
    t.bigint "total_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.text "wa_order_note"
    t.bigint "source_message_id"
    t.integer "review_status", default: 0, null: false
    t.jsonb "validation_issues", default: [], null: false
    t.datetime "decided_at"
    t.string "decided_by"
    t.text "rejection_reason"
    t.index ["customer_id"], name: "index_orders_on_customer_id"
    t.index ["source_message_id"], name: "index_orders_on_source_message_id", unique: true
  end

  create_table "products", force: :cascade do |t|
    t.integer "availability", default: 0, null: false
    t.string "brand"
    t.bigint "category_id", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.text "description"
    t.string "image_url"
    t.string "name", null: false
    t.integer "price_cents", null: false
    t.string "sku", null: false
    t.datetime "updated_at", null: false
    t.string "catalog_synced_digest"
    t.datetime "catalog_synced_at"
    t.text "catalog_sync_error"
    t.index ["category_id"], name: "index_products_on_category_id"
    t.index ["sku"], name: "index_products_on_sku", unique: true
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "webhook_deliveries", force: :cascade do |t|
    t.text "raw_body", null: false
    t.string "body_sha256", limit: 64, null: false
    t.string "signature_header"
    t.string "request_id"
    t.string "object_type"
    t.string "phone_number_id"
    t.jsonb "item_counts", default: {}, null: false
    t.integer "status", default: 0, null: false
    t.integer "attempts", default: 0, null: false
    t.jsonb "outcome", default: {}, null: false
    t.string "last_error_class"
    t.text "last_error_message"
    t.datetime "received_at", null: false
    t.datetime "last_attempted_at"
    t.datetime "processed_at"
    t.integer "replay_count", default: 0, null: false
    t.datetime "last_replayed_at"
    t.string "last_replayed_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "raw_body_base64"
    t.datetime "purged_at"
    t.string "injected_faults", default: [], null: false, array: true
    t.index ["body_sha256"], name: "index_webhook_deliveries_on_body_sha256"
    t.index ["received_at"], name: "index_webhook_deliveries_on_received_at"
    t.index ["status", "received_at"], name: "index_webhook_deliveries_on_status_and_received_at"
  end

  add_foreign_key "conversations", "customers"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "orders"
  add_foreign_key "messages", "webhook_deliveries", on_delete: :nullify
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "orders", "customers"
  add_foreign_key "orders", "messages", column: "source_message_id"
  add_foreign_key "products", "categories"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
