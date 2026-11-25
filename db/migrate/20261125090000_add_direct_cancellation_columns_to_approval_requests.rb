# 管理者による休暇の直接取消（F9 の追加分）の列。列を足すだけで、既存の申請の値は変わらない。
# - cancelled_by_id     … 休暇を直接取り消した管理者（取消申請の承認で取り消された休暇は nil。処理者は取消申請の reviewer）
# - cancellation_reason … 直接取消の理由（必須。取消申請の承認で取り消された休暇は nil）
# 取り消した日時は、既存の cancelled_at を使う（どちらの方法で取り消しても入る）。
class AddDirectCancellationColumnsToApprovalRequests < ActiveRecord::Migration[7.2]
  def change
    add_reference :approval_requests, :cancelled_by, foreign_key: { to_table: :users }
    add_column :approval_requests, :cancellation_reason, :text
  end
end
