# 勤怠（1人1勤務日につき1件）。出勤打刻で作成し、退勤打刻で clock_out_at を埋める。
class CreateAttendances < ActiveRecord::Migration[7.2]
  def change
    create_table :attendances do |t|
      t.references :user, null: false, foreign_key: true, index: false # 下の複合インデックスで代用
      t.date :work_date, null: false        # 勤務日（出勤打刻をした日。JST）
      t.datetime :clock_in_at, null: false  # 出勤時刻
      t.datetime :clock_out_at              # 退勤時刻（勤務中は NULL）

      t.timestamps
    end

    # 同じ人が同じ日に2回出勤打刻できないようにする（二重送信の最終防衛線）
    add_index :attendances, %i[user_id work_date], unique: true
  end
end
