# 有給休暇の付与（F10）。新しい表を作るだけで、既存の表と行は変わらない。
# - granted_on  … 付与日（この日から使える）
# - half_days   … 付与した日数を 0.5日単位の整数で持つ（10日 → 20、7.5日 → 15）。小数の誤差を避けるため
# - expires_on  … 有効期限（この日まで使える。翌日に失効する）。初期値は付与日の2年後
# - granted_by  … 付与を登録した管理者
# 残日数は保存せず、付与と承認済みの有給休暇から毎回計算する（PaidLeaveLedger）。
class CreatePaidLeaveGrants < ActiveRecord::Migration[7.2]
  def change
    create_table :paid_leave_grants do |t|
      t.references :user, null: false, foreign_key: true
      t.date :granted_on, null: false
      t.integer :half_days, null: false
      t.date :expires_on, null: false
      t.references :granted_by, foreign_key: { to_table: :users }
      t.text :note
      t.timestamps
    end
    add_index :paid_leave_grants, [ :user_id, :granted_on ]
    add_check_constraint :paid_leave_grants, "half_days > 0", name: "paid_leave_grants_half_days_positive"
    add_check_constraint :paid_leave_grants, "expires_on >= granted_on", name: "paid_leave_grants_expiry_after_grant"
  end
end
