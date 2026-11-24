# 勤務ルール設定（F6）。組織で1件だけ持つ。行が無いあいだは初期値で動く（WorkRuleSetting.current）
class CreateWorkRuleSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :work_rule_settings do |t|
      # 1件だけにするための列（常に 1。一意制約で2件目を作れないようにする）
      t.integer :singleton_key, null: false, default: 1
      t.integer :scheduled_work_minutes, null: false, default: 480
      t.integer :standard_break_minutes, null: false, default: 60
      # 締め日（15・20・25）。NULL は月末締め
      t.integer :closing_day
      t.integer :overtime_warning_hours, null: false, default: 45
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :work_rule_settings, :singleton_key, unique: true
  end
end
