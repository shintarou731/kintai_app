# アプリ内通知（F16）と、残業の警告を月度ごとに1回だけ送るための記録。
# 既存のデータから通知をさかのぼって作ることはしない（テーブルを作るだけ）。
class CreateNotifications < ActiveRecord::Migration[7.2]
  def change
    create_table :notifications do |t|
      # 受け取る人
      t.references :recipient, null: false, foreign_key: { to_table: :users }, index: false
      # 通知の種類（Notification::KINDS）
      t.string :kind, null: false
      t.string :title, null: false
      t.text :body
      # クリックしたときに移る画面（アプリ内のパス）
      t.string :path
      # きっかけになった操作をした人（承認した管理者など。システムの判定なら nil）
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      # 関連する記録（申請・付与・残業の警告など）
      t.references :subject, polymorphic: true, index: true
      t.datetime :read_at
      t.timestamps
    end
    # 一覧（新しい順）と未読の件数
    add_index :notifications, %i[recipient_id created_at id], name: "index_notifications_on_recipient_and_created"
    add_index :notifications, :recipient_id, where: "read_at IS NULL", name: "index_notifications_on_unread_recipient"

    # 残業の警告（警告ラインの 80%・100%）を、従業員・月度・段階ごとに1回だけにする（一意制約で、同時に判定しても1件）
    create_table :overtime_alerts do |t|
      t.references :user, null: false, foreign_key: true, index: false
      # 月度（「2026-11」。AttendancePeriod#to_param）
      t.string :period_key, null: false
      # 警告ラインに対する段階（80 か 100）
      t.integer :level, null: false
      # 判定した時点の残業（分）と警告ライン（分）
      t.integer :overtime_minutes, null: false
      t.integer :warning_minutes, null: false
      t.timestamps
    end
    add_index :overtime_alerts, %i[user_id period_key level], unique: true
    add_check_constraint :overtime_alerts, "level IN (80, 100)", name: "overtime_alerts_level"
  end
end
