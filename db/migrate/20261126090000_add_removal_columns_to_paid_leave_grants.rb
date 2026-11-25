# 有給休暇の付与の削除を、行を消さずに記録する（F10・スプリント 16.1）。列を足すだけで、既存の行は「削除されていない」付与のまま。
# - removed_at     … 削除した日時（NULL なら削除されていない）
# - removed_by     … 削除した管理者
# - removal_reason … 削除の理由（必須。removed_at と必ず一緒に入る）
# 削除した付与は、残日数・申請できる残り・年5日の対象の判定に使わない（PaidLeaveGrant.kept）。
class AddRemovalColumnsToPaidLeaveGrants < ActiveRecord::Migration[7.2]
  def change
    add_column :paid_leave_grants, :removed_at, :datetime
    add_reference :paid_leave_grants, :removed_by, foreign_key: { to_table: :users }
    add_column :paid_leave_grants, :removal_reason, :text
    add_check_constraint :paid_leave_grants, "(removed_at IS NULL) = (removal_reason IS NULL)",
                         name: "paid_leave_grants_removal_reason_with_removed_at"
  end
end
