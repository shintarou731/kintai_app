# アプリ内通知（F16）。1件の通知は1人の受け取る人（recipient）のもの。作るのは Notifier（と OvertimeAlert）。
#
# - path … クリックしたときに移る画面（アプリ内のパス。作るときに決める）。開くと既読になる（Notifications::ReadingsController）。
# - read_at … 既読にした日時（未読なら nil）。
# - 一覧は新しい順（created_at が通知の発生日時）。
class Notification < ApplicationRecord
  # 通知の種類と、一覧に出す短いラベル・アイコンの色（tone）
  KINDS = {
    "request_submitted" => { label: "新しい申請", tone: "accent" },
    "request_approved" => { label: "承認", tone: "success" },
    "request_rejected" => { label: "却下", tone: "danger" },
    "leave_cancelled_by_admin" => { label: "休暇の取消", tone: "warning" },
    "shift_published" => { label: "シフト公開", tone: "accent" },
    "shift_changed" => { label: "シフト変更", tone: "warning" },
    "paid_leave_granted" => { label: "有給の付与", tone: "success" },
    "overtime_alert" => { label: "残業の警告", tone: "danger" }
  }.freeze

  TITLE_MAX_LENGTH = 200
  BODY_MAX_LENGTH = 1000
  # 一覧の1ページの件数
  PER_PAGE = 20
  # ヘッダーのベルから開く一覧に出す件数
  MENU_LIMIT = 6
  # ヘッダーのバッジに出す件数の上限（超えたら「99+」）
  BADGE_MAX = 99

  belongs_to :recipient, class_name: "User"
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :subject, polymorphic: true, optional: true

  validates :kind, inclusion: { in: KINDS.keys }
  validates :title, presence: true, length: { maximum: TITLE_MAX_LENGTH }
  validates :body, length: { maximum: BODY_MAX_LENGTH }
  validate :path_must_be_internal

  scope :unread, -> { where(read_at: nil) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  # アプリ内のパス（「/requests/12」など）だけを、移る先として認める（外のサイトへ移らないように）
  def self.internal_path?(path)
    path.is_a?(String) && path.start_with?("/") && !path.start_with?("//") && !path.include?("\\") && !path.match?(/[\p{Cc}]/)
  end

  def kind_label
    KINDS.fetch(kind)[:label]
  end

  def tone
    KINDS.fetch(kind)[:tone]
  end

  def read?
    !read_at.nil?
  end

  def unread?
    !read?
  end

  # 移る先（アプリ内のパスでなければ nil）
  def target_path
    path if self.class.internal_path?(path)
  end

  # 既読にする（未読のときだけ書き込む。同時に開いても既読の日時は最初の1回のまま）
  def mark_read!(now: Time.current)
    Notification.where(id: id, read_at: nil).update_all(read_at: now, updated_at: now)
    reload
  end

  private

  def path_must_be_internal
    errors.add(:path, :invalid) if path.present? && !self.class.internal_path?(path)
  end
end
