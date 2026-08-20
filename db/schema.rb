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

ActiveRecord::Schema[8.1].define(version: 2026_08_20_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.bigint "oauth_client_id"
    t.string "refresh_token_digest"
    t.datetime "revoked_at"
    t.string "scope"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["refresh_token_digest"], name: "index_api_tokens_on_refresh_token_digest", unique: true
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id", "revoked_at"], name: "index_api_tokens_on_user_id_and_revoked_at"
  end

  create_table "match_adjustments", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.bigint "match_id", null: false
    t.text "memo", null: false
    t.datetime "updated_at", null: false
    t.index ["match_id"], name: "index_match_adjustments_on_match_id"
  end

  create_table "match_transactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "direction", default: 0, null: false
    t.datetime "dropped_at"
    t.string "hcb_organization_id", null: false
    t.string "hcb_transaction_id", null: false
    t.bigint "match_id", null: false
    t.datetime "undone_at"
    t.datetime "updated_at", null: false
    t.index ["hcb_organization_id", "hcb_transaction_id"], name: "index_match_transactions_on_active_txn_per_org", unique: true, where: "((undone_at IS NULL) AND (dropped_at IS NULL))"
    t.index ["match_id"], name: "index_match_transactions_on_match_id"
  end

  create_table "matches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.integer "discrepancy_cents", default: 0, null: false
    t.string "hcb_organization_id", null: false
    t.datetime "hidden_at"
    t.bigint "hidden_by_user_id"
    t.integer "legacy_id"
    t.text "note"
    t.datetime "undone_at"
    t.bigint "undone_by_user_id"
    t.datetime "updated_at", null: false
    t.index ["hcb_organization_id", "undone_at"], name: "index_matches_on_hcb_organization_id_and_undone_at"
    t.index ["hcb_organization_id"], name: "index_matches_on_hcb_organization_id"
    t.index ["legacy_id"], name: "index_matches_on_legacy_id", unique: true
  end

  create_table "oauth_authorization_codes", force: :cascade do |t|
    t.bigint "api_token_id"
    t.string "code_challenge", null: false
    t.string "code_digest", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "oauth_client_id", null: false
    t.string "redirect_uri", null: false
    t.string "resource"
    t.string "scope", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["code_digest"], name: "index_oauth_authorization_codes_on_code_digest", unique: true
    t.index ["expires_at"], name: "index_oauth_authorization_codes_on_expires_at"
  end

  create_table "oauth_clients", force: :cascade do |t|
    t.string "client_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.jsonb "redirect_uris", default: [], null: false
    t.string "secret_digest"
    t.datetime "updated_at", null: false
    t.index ["client_id"], name: "index_oauth_clients_on_client_id", unique: true
  end

  create_table "organization_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hcb_organization_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_user_id", null: false
    t.string "zero_balance_date"
    t.string "zero_balance_transaction_id"
    t.index ["hcb_organization_id"], name: "index_organization_settings_on_hcb_organization_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.text "access_token"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "hcb_user_id", null: false
    t.string "name"
    t.text "refresh_token"
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.index ["hcb_user_id"], name: "index_users_on_hcb_user_id", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event", null: false
    t.string "hcb_organization_id"
    t.bigint "item_id", null: false
    t.string "item_type", null: false
    t.jsonb "object"
    t.jsonb "object_changes"
    t.string "request_id"
    t.string "whodunnit"
    t.index ["hcb_organization_id", "created_at"], name: "index_versions_on_hcb_organization_id_and_created_at"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
    t.index ["request_id"], name: "index_versions_on_request_id"
  end

  add_foreign_key "api_tokens", "oauth_clients"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "match_adjustments", "matches"
  add_foreign_key "match_adjustments", "users", column: "created_by_user_id"
  add_foreign_key "match_transactions", "matches"
  add_foreign_key "matches", "users", column: "created_by_user_id"
  add_foreign_key "matches", "users", column: "undone_by_user_id"
  add_foreign_key "oauth_authorization_codes", "oauth_clients"
  add_foreign_key "oauth_authorization_codes", "users"
  add_foreign_key "organization_settings", "users", column: "updated_by_user_id"
end
