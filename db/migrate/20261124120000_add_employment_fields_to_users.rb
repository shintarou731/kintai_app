# 従業員管理（F2）のため、雇用区分・入社日・有効/無効の状態を追加する。
# 既存ユーザーは「正社員」「有効」として扱う（入社日は未設定のまま）。
class AddEmploymentFieldsToUsers < ActiveRecord::Migration[7.2]
  def change
    change_table :users, bulk: true do |t|
      t.string :employment_type, null: false, default: "full_time"
      t.date :hired_on
      t.boolean :active, null: false, default: true
    end
    add_index :users, :active
  end
end
