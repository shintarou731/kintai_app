# 1回分の休憩。休憩開始で作成し、休憩終了で ended_at を埋める（休憩中は NULL）。
# 日付をまたぐ休憩（例：23:30〜翌0:30）も、出勤した日の勤怠に属する。
class AttendanceBreak < ApplicationRecord
  belongs_to :attendance, inverse_of: :breaks

  validates :started_at, presence: true
  validate :ended_at_must_not_precede_started_at
  validate :started_at_must_not_precede_clock_in

  scope :ongoing, -> { where(ended_at: nil) }

  def open?
    ended_at.nil?
  end

  # 休憩時間（分）。休憩中なら as_of までで数える。
  # 勤務の時間計算は「分単位の打刻時刻」で行う（Attendance.minutes_between を参照）。
  def duration_minutes(as_of: Time.current)
    Attendance.minutes_between(started_at, ended_at || as_of)
  end

  private

  def ended_at_must_not_precede_started_at
    return if started_at.blank? || ended_at.blank?

    errors.add(:ended_at, :before_started_at) if ended_at < started_at
  end

  def started_at_must_not_precede_clock_in
    return if started_at.blank? || attendance&.clock_in_at.blank?

    errors.add(:started_at, :before_clock_in) if started_at < attendance.clock_in_at
  end
end
