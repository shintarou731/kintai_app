# 月次集計と締め（F14）：月度の締め・締めたときの値・管理者による勤怠の直接修正の履歴の表を作る
# （新しい表だけ。既存の表と行は変えない）。
#
# - monthly_closings：締めた月度。1回締めるごとに1行。解除しても行は消さず、reopened_at・reopened_by を入れて履歴に残す。
#   同じ月度で「締めたまま（解除していない）」の行は1つだけ（部分一意インデックス。2人の管理者が同時に締めても1件になる）。
#   期間（start_date〜end_date）と、締めた時点の勤務ルール（所定労働時間・標準の休憩時間・締め日・警告ライン）を持つ。
#   締めた後に勤務ルールを変えても、この月度はこの期間・このルールのまま。
# - monthly_closing_entries：締めた月度の従業員ごとの集計値（月次集計の表の項目）と、日別の値（snapshot。JSON）。
#   締めた月度の画面（月次集計・日別の勤怠・従業員の勤怠履歴）と CSV（F15）は、ここから読む。
# - attendance_edits：管理者が勤怠を直接修正した履歴（誰が・いつ・何を・なぜ）。修正前・修正後の記録（JSON）を持つ。
class CreateMonthlyClosings < ActiveRecord::Migration[7.2]
  def change
    create_table :monthly_closings do |t|
      t.integer :year, null: false
      t.integer :month, null: false
      t.date :start_date, null: false
      t.date :end_date, null: false
      # 締めた時点の勤務ルール（締め日 nil は月末締め）
      t.integer :closing_day
      t.integer :scheduled_work_minutes, null: false
      t.integer :standard_break_minutes, null: false
      t.integer :overtime_warning_hours, null: false
      t.references :closed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :closed_at, null: false
      t.references :reopened_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :reopened_at
      t.timestamps
    end
    add_index :monthly_closings, %i[year month], unique: true, where: "reopened_at IS NULL",
                                                 name: "index_monthly_closings_on_active_month"
    add_index :monthly_closings, %i[start_date end_date]
    add_check_constraint :monthly_closings, "end_date >= start_date", name: "monthly_closings_period_order"

    create_table :monthly_closing_entries do |t|
      t.references :monthly_closing, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true
      t.integer :working_days, null: false, default: 0
      t.integer :worked_minutes, null: false, default: 0
      t.integer :overtime_minutes, null: false, default: 0
      t.integer :night_minutes, null: false, default: 0
      t.integer :holiday_worked_minutes, null: false, default: 0
      # 日数は 0.5日単位なので、半日の数で持つ（3.5日 → 7）
      t.integer :paid_leave_half_days, null: false, default: 0
      t.integer :absence_leave_half_days, null: false, default: 0
      t.integer :scheduled_days, null: false, default: 0
      t.integer :late_count, null: false, default: 0
      t.integer :early_leave_count, null: false, default: 0
      t.integer :absence_count, null: false, default: 0
      t.integer :missing_clock_out_count, null: false, default: 0
      t.text :snapshot, null: false
      t.timestamps
    end
    add_index :monthly_closing_entries, %i[monthly_closing_id user_id], unique: true

    create_table :attendance_edits do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.date :work_date, null: false
      t.references :editor, null: false, foreign_key: { to_table: :users }
      # created（勤怠が無い日に作った）/ updated（直した）/ deleted（削除した）
      t.string :operation, null: false
      t.text :reason, null: false
      t.text :before_record
      t.text :after_record
      t.timestamps
    end
    add_index :attendance_edits, %i[user_id work_date created_at]
  end
end
