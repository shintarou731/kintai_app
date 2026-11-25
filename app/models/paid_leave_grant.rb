# 有給休暇の付与（F10）。管理者が従業員ごとに、付与日・日数・有効期限を入れて登録する。
#
# - 日数は 0.5日単位（half_days に「0.5日の個数」で持つ。7.5日 → 15）。
# - 有効期限（expires_on）は「この日まで使える」日。翌日から失効する。入力が空なら付与日の2年後（2.years）にする。
#   2/29 に付与した場合の2年後は 2/28（Rails の日付計算に従う）。
# - 付与日は今日まで（未来の付与日は登録できない）。過去の付与（入社時からの付与など）は登録できる。
# - 付与分を使える休暇の日は「付与日〜有効期限」の日。どの付与から消化するかは PaidLeaveLedger が決める（古い付与から）。
# - 削除は、誤って登録した付与を取り除くためのもの。削除すると承認済み・承認待ちの有給が残日数を超える場合は削除できない
#   （PaidLeaveGrantRemoval）。行は消さず、削除した管理者・日時・理由を記録する（removed_at / removed_by / removal_reason）。
#   削除した付与は残日数・申請できる残り・年5日の対象の判定に使わない。付与を数える箇所は kept（削除されていない付与）を使う。
class PaidLeaveGrant < ApplicationRecord
  VALIDITY = 2.years
  MAX_DAYS = 40
  NOTE_MAX_LENGTH = 200
  # 付与日として登録できる最も古い日（今日から何年前まで）
  MAX_PAST_SPAN = 5.years

  belongs_to :user
  belongs_to :granted_by, class_name: "User", optional: true
  belongs_to :removed_by, class_name: "User", optional: true

  attribute :days, :decimal

  normalizes :note, with: ->(note) { note.strip.presence }

  before_validation :convert_days_to_half_days
  before_validation :default_expires_on

  validates :granted_on, presence: true
  validates :expires_on, presence: true
  validates :note, length: { maximum: NOTE_MAX_LENGTH }
  validate :days_must_be_valid
  validate :granted_on_must_be_in_range
  validate :expires_on_must_not_be_before_granted_on

  scope :chronological, -> { order(:granted_on, :expires_on, :id) }
  # 削除されていない付与（残日数などの計算に使う）／削除した付与（履歴に「付与の削除」として出す）
  scope :kept, -> { where(removed_at: nil) }
  scope :removed, -> { where.not(removed_at: nil) }

  # 有効期限の初期値（付与日の2年後）
  def self.default_expiry_for(granted_on)
    granted_on && granted_on + VALIDITY
  end

  # 入力画面の初期値（今日付与・10日・2年後まで）
  def self.build_for(user, today: Date.current)
    new(user: user, granted_on: today, days: 10, expires_on: default_expiry_for(today))
  end

  # 日数の入力が数値として読めるか（「10」「7.5」「７．５」）。読めない入力（「abc」）は decimal にすると 0 になってしまうため、
  # 入力された文字のまま確かめて「数値で入力してください」と知らせる
  NUMERIC_INPUT = /\A[+-]?(\d+(\.\d*)?|\.\d+)\z/

  # 全角の数字・小数点や前後の空白も受け付ける
  def days=(value)
    value = value.unicode_normalize(:nfkc).strip if value.is_a?(String)
    super
  end

  # 入力欄の日数。DB から読んだ付与は half_days から求める
  def days
    value = super
    value.nil? && half_days ? BigDecimal(half_days) / 2 : value
  end

  # 付与した日数（Rational。例：15/2r ＝ 7.5日）
  def granted_days
    half_days.to_i * PaidLeaveLedger::HALF_DAY
  end

  def removed?
    removed_at.present?
  end

  # 削除したことを記録する（PaidLeaveGrantRemoval がトランザクションとロックの中で呼ぶ）。
  # 付与の内容（付与日・日数・有効期限）は変えずに残すので、削除した付与の内容をあとから確かめられる。
  # 付与日の範囲（今日から5年前まで）などは登録時の確かめなので、削除の記録では確かめ直さない（update_columns）。
  def mark_removed!(by:, reason:, now: Time.current)
    raise ArgumentError, "removal reason is required" if reason.blank?

    update_columns(removed_at: now, removed_by_id: by&.id, removal_reason: reason, updated_at: now)
  end

  # date にこの付与分を使えるか（付与日〜有効期限の日）
  def usable_on?(date)
    granted_on <= date && date <= expires_on
  end

  # date の時点で失効しているか（有効期限の翌日から失効）
  def expired_on?(date)
    expires_on < date
  end

  # 使える期間（付与日〜有効期限）が range と1日でも重なるか（年5日の対象の判定。PaidLeaveAccount）
  def usable_during?(range)
    granted_on <= range.end && range.begin <= expires_on
  end

  # date の時点でまだ付与日になっていないか
  def future_on?(date)
    date < granted_on
  end

  private

  # 画面からは days（「7.5」など）で受け取り、0.5日の個数にして保存する
  def convert_days_to_half_days
    return if days.nil?

    raw = days_before_type_cast
    if raw.is_a?(String) && raw.present? && !NUMERIC_INPUT.match?(raw)
      self.half_days = nil
      return
    end

    doubled = days * 2
    self.half_days = doubled == doubled.round ? doubled.to_i : nil
  end

  def default_expires_on
    self.expires_on ||= self.class.default_expiry_for(granted_on)
  end

  def days_must_be_valid
    raw = days_before_type_cast
    if raw.is_a?(String) && raw.present? && !NUMERIC_INPUT.match?(raw)
      errors.add(:days, :not_a_number)
    elsif days.nil? && half_days.nil?
      errors.add(:days, :blank)
    elsif !days.nil? && (days * 2) != (days * 2).round
      errors.add(:days, :half_day_unit)
    elsif half_days.to_i <= 0 || half_days.to_i > MAX_DAYS * 2
      errors.add(:days, :out_of_range, max: MAX_DAYS)
    end
  end

  def granted_on_must_be_in_range
    return if granted_on.nil?

    today = Date.current
    errors.add(:granted_on, :in_future) if granted_on > today
    errors.add(:granted_on, :too_old, date: I18n.l(today - MAX_PAST_SPAN, format: :long)) if granted_on < today - MAX_PAST_SPAN
  end

  def expires_on_must_not_be_before_granted_on
    return if granted_on.nil? || expires_on.nil?

    errors.add(:expires_on, :before_granted_on) if expires_on < granted_on
  end
end
