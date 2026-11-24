# 従業員が出す「申請」。種類（type）で区別する（打刻修正申請＝AttendanceCorrectionRequest。休暇申請も同じ表に並べる想定）。
# 状態は pending（承認待ち）/ approved（承認済み）/ rejected（却下）/ withdrawn（取り下げ）。
class CreateApprovalRequests < ActiveRecord::Migration[7.2]
  def change
    create_table :approval_requests do |t|
      t.references :user, null: false, foreign_key: true    # 申請者
      t.string :type, null: false                           # 申請の種類（STI）
      t.string :status, null: false, default: "pending"     # 状態
      t.date :target_date, null: false                      # 対象日（打刻修正申請では勤務日）
      t.text :reason, null: false                           # 申請の理由
      t.datetime :withdrawn_at                              # 取り下げた日時

      # 打刻修正申請の内容（申請する正しい出勤・退勤の時刻。退勤は勤務中の当日なら空のこともある）
      t.datetime :requested_clock_in_at
      t.datetime :requested_clock_out_at

      t.timestamps
    end

    add_index :approval_requests, %i[user_id created_at]
    add_index :approval_requests, %i[status created_at]
    # 同じ人・同じ種類・同じ対象日の「承認待ち」は1件まで（同時送信の最終防衛線）
    add_index :approval_requests, %i[user_id type target_date], unique: true, where: "status = 'pending'",
                                                                name: "index_approval_requests_on_pending_target"

    # 打刻修正申請で申請する休憩（1件の申請に複数）
    create_table :attendance_correction_breaks do |t|
      t.references :approval_request, null: false, foreign_key: true
      t.datetime :started_at, null: false
      t.datetime :ended_at, null: false

      t.timestamps
    end
  end
end
