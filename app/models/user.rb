class User < ApplicationRecord
  PASSWORD_MIN_LENGTH = 8

  # 管理者が従業員を登録・編集するときのバリデーションコンテキスト（入社日を必須にする）
  STAFF_FORM_CONTEXT = :staff_form

  INACTIVE_LOGIN_MESSAGE = "このアカウントは無効になっているため、ログインできません。管理者にお問い合わせください。".freeze

  has_secure_password

  has_many :attendances, dependent: :destroy
  has_many :approval_requests, dependent: :destroy
  has_many :attendance_correction_requests, dependent: :destroy
  # 休暇申請と取消申請（approval_requests の一部。削除は approval_requests の dependent に任せる）
  has_many :leave_requests, inverse_of: :user
  has_many :leave_cancellation_requests, inverse_of: :user
  # 有給休暇の付与（F10）。paid_leave_grants は削除されていない付与だけ（残日数などの計算に使う）。
  # 削除した付与は removed_paid_leave_grants（履歴の「付与の削除」に出す）。
  has_many :paid_leave_grants, -> { kept.chronological }, dependent: :destroy, inverse_of: :user
  has_many :removed_paid_leave_grants, -> { removed.order(:removed_at, :id) }, class_name: "PaidLeaveGrant", dependent: :destroy
  # シフト（F11）
  has_many :shifts, dependent: :destroy
  # アプリ内通知（F16。自分が受け取ったもの）と、残業の警告を送った記録
  has_many :notifications, foreign_key: :recipient_id, inverse_of: :recipient, dependent: :destroy
  has_many :overtime_alerts, dependent: :destroy

  enum :role, { employee: "employee", admin: "admin" }, default: :employee, validate: true
  enum :employment_type, { full_time: "full_time", part_time: "part_time" }, default: :full_time, validate: true

  normalizes :email, with: ->(email) { email.strip.downcase }
  normalizes :name, with: ->(name) { name.strip }

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :active_admins, -> { admin.active }
  scope :ordered_for_list, -> { order(active: :desc, id: :asc) }

  # 自分自身を操作しているときの判定に使う（操作した管理者を入れる）
  attr_accessor :editor
  # 本人のパスワード変更時に入力された「現在のパスワード」（エラー表示用。保存はしない）
  attr_accessor :current_password

  validates :name, presence: true, length: { maximum: 50 }
  # 改行・タブなどの制御文字は氏名に入れない（画面の入力欄では入らないが、フォームの値を直接送ると入りうる。表示や CSV が崩れるため）
  validates :name, format: { without: /[\p{Cc}\p{Zl}\p{Zp}]/, message: :control_characters }
  validates :email, presence: true,
                    length: { maximum: 255 },
                    format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true },
                    uniqueness: true
  validates :password, length: { minimum: PASSWORD_MIN_LENGTH }, allow_nil: true
  validates :hired_on, presence: true, on: STAFF_FORM_CONTEXT

  validate :editor_cannot_demote_or_deactivate_self
  validate :keep_at_least_one_active_admin

  # 初期セットアップ（最初の管理者作成）が必要かどうか
  def self.setup_required?
    none?
  end

  # メールアドレスとパスワードで認証する。失敗時は nil を返す。
  # 無効化されたユーザーも返すため、呼び出し側で active? を確認すること。
  def self.authenticate_by_credentials(email, password)
    authenticate_by(email: email.to_s.strip.downcase, password: password.to_s)
  end

  # 役割の表示名（例：「管理者」）
  def role_label
    self.class.human_enum_value(:role, role)
  end

  # 雇用区分の表示名（例：「パート・アルバイト」）
  def employment_type_label
    self.class.human_enum_value(:employment_type, employment_type)
  end

  # 状態の表示名
  def status_label
    active? ? "有効" : "無効"
  end

  def self.human_enum_value(attribute, value)
    I18n.t("enums.user.#{attribute}.#{value}")
  end

  # 選択肢（表示名, 値）の配列
  def self.enum_options(attribute)
    public_send(attribute.to_s.pluralize).keys.map { |value| [ human_enum_value(attribute, value), value ] }
  end

  # 本人によるパスワード変更。現在のパスワードの確認が必要。
  def change_password(current_password:, new_password:, new_password_confirmation:)
    unless authenticate(current_password.to_s)
      errors.add(:current_password, :incorrect)
      return false
    end

    reset_password(new_password, new_password_confirmation)
  end

  # 管理者によるパスワード再設定（確認欄は任意）
  def reset_password(new_password, new_password_confirmation = nil)
    if new_password.blank?
      errors.add(:password, :blank)
      return false
    end

    self.password = new_password
    self.password_confirmation = new_password_confirmation unless new_password_confirmation.nil?
    save
  end

  def activate
    self.active = true
    save_keeping_active_admin
  end

  def deactivate
    self.active = false
    save_keeping_active_admin
  end

  # 役割・有効/無効を変える保存はこのメソッドを使う（同時操作対策）。
  # keep_at_least_one_active_admin は「保存前の確認」なので、2人の管理者が同時に互いを
  # 無効化すると両方とも確認を通り抜けうる。そこで同じトランザクション内で保存後にも
  # 有効な管理者の人数を数え直し、0人になっていたら変更を取り消す。
  # - PostgreSQL などでは、先に有効な管理者の行をロックして操作を順番待ちにする。
  # - SQLite は書き込みが1つずつしか行われないため、後から書いた側は先の変更を見て取り消される
  #   （またはデータベースのロック待ちエラーで失敗する）。どちらでも管理者が0人にはならない。
  def save_keeping_active_admin(**options)
    saved = false
    self.class.transaction(requires_new: true) do
      self.class.active_admins.lock.ids
      saved = save(**options)
      if saved && self.class.active_admins.none?
        saved = false
        errors.add(:base, :last_active_admin)
        raise ActiveRecord::Rollback
      end
    end
    saved
  end

  private

  def editing_self?
    editor.present? && editor.id == id
  end

  def editor_cannot_demote_or_deactivate_self
    return unless editing_self?

    errors.add(:role, :cannot_demote_self) if will_save_change_to_role? && !admin?
    errors.add(:base, :cannot_deactivate_self) if will_save_change_to_active? && !active?
  end

  # 有効な管理者が1人もいなくなる変更（役割の変更・無効化）を防ぐ
  def keep_at_least_one_active_admin
    return if new_record? || editing_self? # 自分自身の変更は editor_cannot_demote_or_deactivate_self で防ぐ
    return unless role_in_database == "admin" && active_in_database
    return if admin? && active?
    return if self.class.active_admins.where.not(id: id).exists?

    errors.add(:base, :last_active_admin)
  end
end
