# 1人・1勤務日分の勤怠。勤務日（work_date）は出勤打刻をした日（JST）で、
# 日付をまたいで退勤しても出勤した日の勤務として扱う。
#
# 時間の計算は「分単位の打刻時刻」で行う。打刻時刻は秒まで記録するが、
# 画面に出る時刻（09:02 など）と同じく秒を切り捨てた時刻どうしの差で、
# 実働・休憩の時間を求める（例：22:00:11 出勤 → 02:00:08 退勤は 4:00）。
class Attendance < ApplicationRecord
  belongs_to :user
  has_many :breaks, -> { order(:started_at, :id) }, class_name: "AttendanceBreak",
                                                    dependent: :destroy, inverse_of: :attendance

  validates :work_date, presence: true, uniqueness: { scope: :user_id }
  validates :clock_in_at, presence: true
  validate :clock_out_must_not_precede_clock_in

  scope :without_clock_out, -> { where(clock_out_at: nil) }

  # 2つの時刻の差（分）。どちらも秒を切り捨ててから差をとる。負になる場合は 0
  def self.minutes_between(from, to)
    return 0 if from.nil? || to.nil?

    [ ((to.change(sec: 0) - from.change(sec: 0)) / 60).floor, 0 ].max
  end

  def clocked_out?
    clock_out_at.present?
  end

  # 休憩中の休憩（無ければ nil）
  def open_break
    breaks.detect(&:open?)
  end

  def on_break?
    !clocked_out? && open_break.present?
  end

  # 終わった休憩
  def finished_breaks
    breaks.reject(&:open?)
  end

  # 出勤〜退勤（勤務中なら as_of まで）の時間（分）
  def elapsed_minutes(as_of: Time.current)
    self.class.minutes_between(clock_in_at, ending_at(as_of))
  end

  # 休憩の合計時間（分）。休憩中の休憩は as_of までで数える
  def break_minutes(as_of: Time.current)
    breaks.sum { |item| item.duration_minutes(as_of: ending_at(as_of)) }
  end

  # 終わった休憩だけの合計時間（分）
  def finished_break_minutes
    finished_breaks.sum(&:duration_minutes)
  end

  # 実働時間（分）＝ 出勤〜退勤 − 休憩合計
  def worked_minutes(as_of: Time.current)
    [ elapsed_minutes(as_of: as_of) - break_minutes(as_of: as_of), 0 ].max
  end

  # 残業時間（分）＝ 実働時間のうち所定労働時間（scheduled_minutes）を超えた部分
  def overtime_minutes(scheduled_minutes:, as_of: Time.current)
    [ worked_minutes(as_of: as_of) - scheduled_minutes, 0 ].max
  end

  # 深夜時間（分）＝ 22:00〜翌5:00 の間に働いた時間。深夜帯にかかる休憩は差し引く。
  # 実働時間と同じく、秒を切り捨てた時刻で数える
  def night_minutes(as_of: Time.current)
    from = clock_in_at.in_time_zone.change(sec: 0)
    to = ending_at(as_of).in_time_zone.change(sec: 0)
    return 0 if to <= from

    windows = night_windows(from, to)
    working = windows.sum { |window| overlap_minutes(from, to, window) }
    resting = breaks.sum do |item|
      break_from = [ item.started_at.in_time_zone.change(sec: 0), from ].max
      break_to = [ (item.ended_at || to).in_time_zone.change(sec: 0), to ].min
      windows.sum { |window| overlap_minutes(break_from, break_to, window) }
    end
    [ working - resting, 0 ].max
  end

  # 退勤の打刻が無いまま、勤務日（出勤した日）が過ぎた勤務か（勤怠履歴の「退勤漏れ」）。
  # 日付をまたいだ勤務も、退勤するまでは退勤漏れとして扱う（ホームから退勤できるかは clock_out_open? で判断する）
  def missing_clock_out?(as_of: Time.current)
    !clocked_out? && work_date < as_of.in_time_zone.to_date
  end

  # ホーム画面から退勤を打刻できる期限（出勤から TimeClock::MAX_SHIFT_DURATION）。
  # 画面に出す期限（「11/11(水) 10:00 まで」）と判定を一致させるため、出勤時刻の秒を切り捨てて数える
  # （10:00:08 出勤なら、期限は翌日 10:00:00）
  def clock_out_deadline
    TimeClock.clock_out_deadline_for(clock_in_at)
  end

  # まだ退勤しておらず、ホーム画面から退勤を打刻できる期限内の勤務か（TimeClock#current_attendance と同じ基準）
  def clock_out_open?(as_of: Time.current)
    !clocked_out? && as_of <= clock_out_deadline
  end

  # 退勤が出勤と別の日付になった勤務か（例：22:00 出勤 → 翌 2:00 退勤）
  def overnight?(as_of: Time.current)
    ending_at(as_of).in_time_zone.to_date > work_date
  end

  private

  # from〜to にかかる深夜の時間帯（各日の 22:00〜翌5:00）。前日 22:00〜当日 5:00 の帯も含める
  def night_windows(from, to)
    (from.to_date.yesterday..to.to_date).map do |date|
      start = date.in_time_zone.change(hour: WorkRules::NIGHT_START_HOUR)
      start..(date.tomorrow.in_time_zone.change(hour: WorkRules::NIGHT_END_HOUR))
    end
  end

  # from〜to と時間帯 window が重なる時間（分）
  def overlap_minutes(from, to, window)
    self.class.minutes_between([ from, window.begin ].max, [ to, window.end ].min)
  end

  # 計算の終点。退勤済みなら退勤時刻、勤務中なら as_of
  def ending_at(as_of)
    clock_out_at || as_of
  end

  def clock_out_must_not_precede_clock_in
    return if clock_in_at.blank? || clock_out_at.blank?

    errors.add(:clock_out_at, :before_clock_in) if clock_out_at < clock_in_at
  end
end
