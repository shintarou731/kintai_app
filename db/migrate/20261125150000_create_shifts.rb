# シフト作成（F11）：シフトパターン・シフト・週ごとの公開の記録の表を作る（新しい表だけ。既存の表と行は変えない）。
#
# - 時刻は「その日の 0:00 からの分」（0〜1439）で持つ。終了が開始より前なら、日付をまたいで翌日に終わる（22:00〜翌6:00）。
#   終了＝開始は勤務時間が0になるので、DB の制約でも拒否する。
# - シフトの work_date は、シフトが始まる日（日付をまたぐシフトも、開始した日のシフトとして扱う）。1人1日1件。
# - 管理者が編集するのは start_minute / end_minute / break_minutes（下書き）。従業員に見せるのは、
#   週の「公開」で写した published_* の列だけ（公開するまで、変更も従業員には見えない）。
# - lock_version は楽観的ロック（2人の管理者が同じマスを同時に編集したときに、後から保存した側を止める）。
class CreateShifts < ActiveRecord::Migration[7.2]
  def change
    create_table :shift_patterns do |t|
      t.string :name, null: false
      t.integer :start_minute, null: false
      t.integer :end_minute, null: false
      t.integer :break_minutes, null: false, default: 0
      t.timestamps
    end
    add_index :shift_patterns, :name, unique: true
    add_check_constraint :shift_patterns, "start_minute BETWEEN 0 AND 1439 AND end_minute BETWEEN 0 AND 1439",
                         name: "shift_patterns_minutes_in_day"
    add_check_constraint :shift_patterns, "start_minute <> end_minute", name: "shift_patterns_not_zero_length"
    add_check_constraint :shift_patterns, "break_minutes >= 0", name: "shift_patterns_break_not_negative"

    create_table :shifts do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.date :work_date, null: false
      t.integer :start_minute, null: false
      t.integer :end_minute, null: false
      t.integer :break_minutes, null: false, default: 0
      # 公開済みのシフトを管理者が削除したとき（次の公開で消える。それまでは従業員には公開中の内容が見える）
      t.datetime :removed_at
      # 従業員に見せる内容（最後に公開した時点の内容。一度も公開していなければ nil）
      t.integer :published_start_minute
      t.integer :published_end_minute
      t.integer :published_break_minutes
      t.datetime :published_at
      # 公開済みの内容が、再公開で変わった日時（従業員の画面で「変更あり」を示すため）
      t.datetime :revised_at
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :shifts, %i[user_id work_date], unique: true
    add_index :shifts, :work_date
    add_check_constraint :shifts, "start_minute BETWEEN 0 AND 1439 AND end_minute BETWEEN 0 AND 1439",
                         name: "shifts_minutes_in_day"
    add_check_constraint :shifts, "start_minute <> end_minute", name: "shifts_not_zero_length"
    add_check_constraint :shifts, "break_minutes >= 0", name: "shifts_break_not_negative"

    create_table :shift_publications do |t|
      t.date :week_start, null: false
      t.references :published_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :added_count, null: false, default: 0
      t.integer :changed_count, null: false, default: 0
      t.integer :removed_count, null: false, default: 0
      t.datetime :published_at, null: false
      t.timestamps
    end
    add_index :shift_publications, %i[week_start published_at]
  end
end
