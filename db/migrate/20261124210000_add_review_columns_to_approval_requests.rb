# 申請の承認・却下（F8）の記録。列を足すだけで、既存の申請の値は変わらない（承認待ち・取り下げのまま）。
# - reviewer_id     … 承認・却下した管理者
# - reviewed_at     … 承認・却下した日時
# - review_comment  … 管理者のコメント（却下時は必須）
# - reviewed_record … 承認・却下した時点の勤怠記録（JSON）。承認後も「承認前の記録」と申請内容を比べられるように残す
class AddReviewColumnsToApprovalRequests < ActiveRecord::Migration[7.2]
  def change
    add_reference :approval_requests, :reviewer, foreign_key: { to_table: :users }
    add_column :approval_requests, :reviewed_at, :datetime
    add_column :approval_requests, :review_comment, :text
    add_column :approval_requests, :reviewed_record, :text
    add_index :approval_requests, [ :status, :reviewed_at ]
  end
end
