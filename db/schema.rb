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

ActiveRecord::Schema[7.2].define(version: 2026_11_26_090000) do
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

  create_table "attendance_edits", force: :cascade do |t|
    t.integer "user_id", null: false
    t.date "work_date", null: false
    t.integer "editor_id", null: false
    t.string "operation", null: false
    t.text "reason", null: false
    t.text "before_record"
    t.text "after_record"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["editor_id"], name: "index_attendance_edits_on_editor_id"
    t.index ["user_id", "work_date", "created_at"], name: "index_attendance_edits_on_user_id_and_work_date_and_created_at"
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

  create_table "monthly_closing_entries", force: :cascade do |t|
    t.integer "monthly_closing_id", null: false
    t.integer "user_id", null: false
    t.integer "working_days", default: 0, null: false
    t.integer "worked_minutes", default: 0, null: false
    t.integer "overtime_minutes", default: 0, null: false
    t.integer "night_minutes", default: 0, null: false
    t.integer "holiday_worked_minutes", default: 0, null: false
    t.integer "paid_leave_half_days", default: 0, null: false
    t.integer "absence_leave_half_days", default: 0, null: false
    t.integer "scheduled_days", default: 0, null: false
    t.integer "late_count", default: 0, null: false
    t.integer "early_leave_count", default: 0, null: false
    t.integer "absence_count", default: 0, null: false
    t.integer "missing_clock_out_count", default: 0, null: false
    t.text "snapshot", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["monthly_closing_id", "user_id"], name: "idx_on_monthly_closing_id_user_id_41552e5460", unique: true
    t.index ["user_id"], name: "index_monthly_closing_entries_on_user_id"
  end

  create_table "monthly_closings", force: :cascade do |t|
    t.integer "year", null: false
    t.integer "month", null: false
    t.date "start_date", null: false
    t.date "end_date", null: false
    t.integer "closing_day"
    t.integer "scheduled_work_minutes", null: false
    t.integer "standard_break_minutes", null: false
    t.integer "overtime_warning_hours", null: false
    t.integer "closed_by_id"
    t.datetime "closed_at", null: false
    t.integer "reopened_by_id"
    t.datetime "reopened_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["closed_by_id"], name: "index_monthly_closings_on_closed_by_id"
    t.index ["reopened_by_id"], name: "index_monthly_closings_on_reopened_by_id"
    t.index ["start_date", "end_date"], name: "index_monthly_closings_on_start_date_and_end_date"
    t.index ["year", "month"], name: "index_monthly_closings_on_active_month", unique: true, where: "reopened_at IS NULL"
    t.check_constraint "end_date >= start_date", name: "monthly_closings_period_order"
  end

  create_table "notifications", force: :cascade do |t|
    t.integer "recipient_id", null: false
    t.string "kind", null: false
    t.string "title", null: false
    t.text "body"
    t.string "path"
    t.integer "actor_id"
    t.string "subject_type"
    t.integer "subject_id"
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_notifications_on_actor_id"
    t.index ["recipient_id", "created_at", "id"], name: "index_notifications_on_recipient_and_created"
    t.index ["recipient_id"], name: "index_notifications_on_unread_recipient", where: "read_at IS NULL"
    t.index ["subject_type", "subject_id"], name: "index_notifications_on_subject"
  end

  create_table "overtime_alerts", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "period_key", null: false
    t.integer "level", null: false
    t.integer "overtime_minutes", null: false
    t.integer "warning_minutes", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "period_key", "level"], name: "index_overtime_alerts_on_user_id_and_period_key_and_level", unique: true
    t.check_constraint "level IN (80, 100)", name: "overtime_alerts_level"
  end

  create_table "paid_leave_grants", force: :cascade do |t|
    t.integer "user_id", null: false
    t.date "granted_on", null: false
    t.integer "half_days", null: false
    t.date "expires_on", null: false
    t.integer "granted_by_id"
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "removed_at"
    t.integer "removed_by_id"
    t.text "removal_reason"
    t.index ["granted_by_id"], name: "index_paid_leave_grants_on_granted_by_id"
    t.index ["removed_by_id"], name: "index_paid_leave_grants_on_removed_by_id"
    t.index ["user_id", "granted_on"], name: "index_paid_leave_grants_on_user_id_and_granted_on"
    t.index ["user_id"], name: "index_paid_leave_grants_on_user_id"
    t.check_constraint "(removed_at IS NULL) = (removal_reason IS NULL)", name: "paid_leave_grants_removal_reason_with_removed_at"
    t.check_constraint "expires_on >= granted_on", name: "paid_leave_grants_expiry_after_grant"
    t.check_constraint "half_days > 0", name: "paid_leave_grants_half_days_positive"
  end

  create_table "shift_patterns", force: :cascade do |t|
    t.string "name", null: false
    t.integer "start_minute", null: false
    t.integer "end_minute", null: false
    t.integer "break_minutes", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_shift_patterns_on_name", unique: true
    t.check_constraint "break_minutes >= 0", name: "shift_patterns_break_not_negative"
    t.check_constraint "start_minute <> end_minute", name: "shift_patterns_not_zero_length"
    t.check_constraint "start_minute BETWEEN 0 AND 1439 AND end_minute BETWEEN 0 AND 1439", name: "shift_patterns_minutes_in_day"
  end

  create_table "shift_publications", force: :cascade do |t|
    t.date "week_start", null: false
    t.integer "published_by_id"
    t.integer "added_count", default: 0, null: false
    t.integer "changed_count", default: 0, null: false
    t.integer "removed_count", default: 0, null: false
    t.datetime "published_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["published_by_id"], name: "index_shift_publications_on_published_by_id"
    t.index ["week_start", "published_at"], name: "index_shift_publications_on_week_start_and_published_at"
  end

  create_table "shifts", force: :cascade do |t|
    t.integer "user_id", null: false
    t.date "work_date", null: false
    t.integer "start_minute", null: false
    t.integer "end_minute", null: false
    t.integer "break_minutes", default: 0, null: false
    t.datetime "removed_at"
    t.integer "published_start_minute"
    t.integer "published_end_minute"
    t.integer "published_break_minutes"
    t.datetime "published_at"
    t.datetime "revised_at"
    t.integer "created_by_id"
    t.integer "updated_by_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_shifts_on_created_by_id"
    t.index ["updated_by_id"], name: "index_shifts_on_updated_by_id"
    t.index ["user_id", "work_date"], name: "index_shifts_on_user_id_and_work_date", unique: true
    t.index ["work_date"], name: "index_shifts_on_work_date"
    t.check_constraint "break_minutes >= 0", name: "shifts_break_not_negative"
    t.check_constraint "start_minute <> end_minute", name: "shifts_not_zero_length"
    t.check_constraint "start_minute BETWEEN 0 AND 1439 AND end_minute BETWEEN 0 AND 1439", name: "shifts_minutes_in_day"
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
  add_foreign_key "attendance_edits", "users"
  add_foreign_key "attendance_edits", "users", column: "editor_id"
  add_foreign_key "attendances", "users"
  add_foreign_key "monthly_closing_entries", "monthly_closings"
  add_foreign_key "monthly_closing_entries", "users"
  add_foreign_key "monthly_closings", "users", column: "closed_by_id", on_delete: :nullify
  add_foreign_key "monthly_closings", "users", column: "reopened_by_id", on_delete: :nullify
  add_foreign_key "notifications", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "notifications", "users", column: "recipient_id"
  add_foreign_key "overtime_alerts", "users"
  add_foreign_key "paid_leave_grants", "users"
  add_foreign_key "paid_leave_grants", "users", column: "granted_by_id"
  add_foreign_key "paid_leave_grants", "users", column: "removed_by_id"
  add_foreign_key "shift_publications", "users", column: "published_by_id", on_delete: :nullify
  add_foreign_key "shifts", "users"
  add_foreign_key "shifts", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "shifts", "users", column: "updated_by_id", on_delete: :nullify
  add_foreign_key "work_rule_settings", "users", column: "updated_by_id", on_delete: :nullify
end
