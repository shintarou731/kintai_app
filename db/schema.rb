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

ActiveRecord::Schema[7.2].define(version: 2026_11_25_090000) do
  create_table "approval_requests", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "type", null: false
    t.string "status", default: "pending", null: false
    t.date "target_date", null: false
    t.text "reason", null: false
    t.datetime "withdrawn_at"
    t.datetime "requested_clock_in_at"
    t.datetime "requested_clock_out_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "reviewer_id"
    t.datetime "reviewed_at"
    t.text "review_comment"
    t.text "reviewed_record"
    t.date "end_date"
    t.string "leave_type"
    t.string "day_part"
    t.datetime "cancelled_at"
    t.integer "leave_request_id"
    t.integer "cancelled_by_id"
    t.text "cancellation_reason"
    t.index ["cancelled_by_id"], name: "index_approval_requests_on_cancelled_by_id"
    t.index ["leave_request_id"], name: "index_approval_requests_on_leave_request_id"
    t.index ["reviewer_id"], name: "index_approval_requests_on_reviewer_id"
    t.index ["status", "created_at"], name: "index_approval_requests_on_status_and_created_at"
    t.index ["status", "reviewed_at"], name: "index_approval_requests_on_status_and_reviewed_at"
    t.index ["user_id", "created_at"], name: "index_approval_requests_on_user_id_and_created_at"
    t.index ["user_id", "type", "status", "target_date", "end_date"], name: "index_approval_requests_on_leave_period"
    t.index ["user_id", "type", "target_date"], name: "index_approval_requests_on_pending_target", unique: true, where: "status = 'pending'"
    t.index ["user_id"], name: "index_approval_requests_on_user_id"
  end

  create_table "attendance_breaks", force: :cascade do |t|
    t.integer "attendance_id", null: false
    t.datetime "started_at", null: false
    t.datetime "ended_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["attendance_id"], name: "index_attendance_breaks_on_attendance_id"
    t.index ["attendance_id"], name: "index_attendance_breaks_on_open_break", unique: true, where: "ended_at IS NULL"
  end

  create_table "attendance_correction_breaks", force: :cascade do |t|
    t.integer "approval_request_id", null: false
    t.datetime "started_at", null: false
    t.datetime "ended_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["approval_request_id"], name: "index_attendance_correction_breaks_on_approval_request_id"
  end

  create_table "attendances", force: :cascade do |t|
    t.integer "user_id", null: false
    t.date "work_date", null: false
    t.datetime "clock_in_at", null: false
    t.datetime "clock_out_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "work_date"], name: "index_attendances_on_user_id_and_work_date", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "name", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "role", default: "employee", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "employment_type", default: "full_time", null: false
    t.date "hired_on"
    t.boolean "active", default: true, null: false
    t.index ["active"], name: "index_users_on_active"
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  create_table "work_rule_settings", force: :cascade do |t|
    t.integer "singleton_key", default: 1, null: false
    t.integer "scheduled_work_minutes", default: 480, null: false
    t.integer "standard_break_minutes", default: 60, null: false
    t.integer "closing_day"
    t.integer "overtime_warning_hours", default: 45, null: false
    t.integer "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["singleton_key"], name: "index_work_rule_settings_on_singleton_key", unique: true
    t.index ["updated_by_id"], name: "index_work_rule_settings_on_updated_by_id"
  end

  add_foreign_key "approval_requests", "approval_requests", column: "leave_request_id"
  add_foreign_key "approval_requests", "users"
  add_foreign_key "approval_requests", "users", column: "cancelled_by_id"
  add_foreign_key "approval_requests", "users", column: "reviewer_id"
  add_foreign_key "attendance_breaks", "attendances"
  add_foreign_key "attendance_correction_breaks", "approval_requests"
  add_foreign_key "attendances", "users"
  add_foreign_key "work_rule_settings", "users", column: "updated_by_id", on_delete: :nullify
end
