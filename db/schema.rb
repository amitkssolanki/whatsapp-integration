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

ActiveRecord::Schema[8.1].define(version: 2026_08_08_043416) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
    t.index ["customer_id"], name: "index_conversations_on_customer_id", unique: true
  end

  create_table "customers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name"
    t.boolean "opted_in", default: true, null: false
    t.datetime "updated_at", null: false
    t.string "whatsapp_number", null: false
    t.index ["whatsapp_number"], name: "index_customers_on_whatsapp_number", unique: true
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
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
  end

  create_table "order_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.integer "item_price_cents", default: 0, null: false
    t.bigint "order_id", null: false
    t.bigint "product_id"
    t.string "product_retailer_id", null: false
    t.integer "quantity", default: 1, null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_id"], name: "index_order_items_on_product_id"
  end

  create_table "orders", force: :cascade do |t|
    t.string "catalog_id"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.bigint "customer_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "total_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.text "wa_order_note"
    t.index ["customer_id"], name: "index_orders_on_customer_id"
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
    t.index ["category_id"], name: "index_products_on_category_id"
    t.index ["sku"], name: "index_products_on_sku", unique: true
  end

  add_foreign_key "conversations", "customers"
  add_foreign_key "messages", "conversations"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "orders", "customers"
  add_foreign_key "products", "categories"
end
