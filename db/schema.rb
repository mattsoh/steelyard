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

ActiveRecord::Schema[8.0].define(version: 2026_07_02_215608) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "match_adjustments", force: :cascade do |t|
    t.bigint "match_id", null: false
    t.integer "amount_cents", null: false
    t.text "memo", null: false
    t.bigint "created_by_user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["match_id"], name: "index_match_adjustments_on_match_id"
  end

  create_table "match_transactions", force: :cascade do |t|
    t.bigint "match_id", null: false
    t.string "hcb_organization_id", null: false
    t.string "hcb_transaction_id", null: false
    t.integer "direction", default: 0, null: false
    t.datetime "undone_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hcb_organization_id", "hcb_transaction_id"], name: "index_match_transactions_on_active_txn_per_org", unique: true, where: "(undone_at IS NULL)"
    t.index ["match_id"], name: "index_match_transactions_on_match_id"
  end

  create_table "matches", force: :cascade do |t|
    t.string "hcb_organization_id", null: false
    t.text "note"
    t.integer "discrepancy_cents", default: 0, null: false
    t.bigint "created_by_user_id", null: false
    t.datetime "undone_at"
    t.bigint "undone_by_user_id"
    t.integer "legacy_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hcb_organization_id", "undone_at"], name: "index_matches_on_hcb_organization_id_and_undone_at"
    t.index ["hcb_organization_id"], name: "index_matches_on_hcb_organization_id"
    t.index ["legacy_id"], name: "index_matches_on_legacy_id", unique: true
  end

  create_table "organization_settings", force: :cascade do |t|
    t.string "hcb_organization_id", null: false
    t.string "zero_balance_transaction_id"
    t.string "zero_balance_date"
    t.bigint "updated_by_user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hcb_organization_id"], name: "index_organization_settings_on_hcb_organization_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "hcb_user_id", null: false
    t.string "email"
    t.string "name"
    t.text "access_token"
    t.text "refresh_token"
    t.datetime "token_expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hcb_user_id"], name: "index_users_on_hcb_user_id", unique: true
  end

  add_foreign_key "match_adjustments", "matches"
  add_foreign_key "match_adjustments", "users", column: "created_by_user_id"
  add_foreign_key "match_transactions", "matches"
  add_foreign_key "matches", "users", column: "created_by_user_id"
  add_foreign_key "matches", "users", column: "undone_by_user_id"
  add_foreign_key "organization_settings", "users", column: "updated_by_user_id"
end
