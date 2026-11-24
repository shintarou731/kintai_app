# 休暇申請（F9）の列。列を足すだけで、既存の申請（打刻修正申請）の値は変わらない。
# 休暇申請（LeaveRequest）は、target_date を「開始日」として使う。
# - end_date         … 休暇の終了日（1日だけの休暇・半休なら開始日と同じ）
# - leave_type       … 休暇の種類（paid＝有給休暇 / special＝特別休暇 / absence＝欠勤）
# - day_part         … 区分（full_day＝全日 / morning＝午前半休 / afternoon＝午後半休）
# - cancelled_at     … 承認済みの休暇が、取消申請の承認で取り消された日時
# - leave_request_id … 休暇の取消申請（LeaveCancellationRequest）が取り消す休暇申請
class AddLeaveColumnsToApprovalRequests < ActiveRecord::Migration[7.2]
  def change
    add_column :approval_requests, :end_date, :date
    add_column :approval_requests, :leave_type, :string
    add_column :approval_requests, :day_part, :string
    add_column :approval_requests, :cancelled_at, :datetime
    add_reference :approval_requests, :leave_request, foreign_key: { to_table: :approval_requests }
    # 期間の重なりの確認・勤怠履歴への表示で、本人の休暇を期間で探す
    add_index :approval_requests, %i[user_id type status target_date end_date],
              name: "index_approval_requests_on_leave_period"
  end
end
