# 休憩（1つの勤怠に複数回）。休憩開始で作成し、休憩終了で ended_at を埋める。
class CreateAttendanceBreaks < ActiveRecord::Migration[7.2]
  def change
    create_table :attendance_breaks do |t|
      t.references :attendance, null: false, foreign_key: true
      t.datetime :started_at, null: false # 休憩開始時刻
      t.datetime :ended_at                # 休憩終了時刻（休憩中は NULL）

      t.timestamps
    end

    # 1つの勤怠で「休憩中（終了していない休憩）」は1件まで（二重送信の最終防衛線）
    add_index :attendance_breaks, :attendance_id, unique: true, where: "ended_at IS NULL",
                                                  name: "index_attendance_breaks_on_open_break"
  end
end
