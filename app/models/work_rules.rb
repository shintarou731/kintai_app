# 勤怠の計算に使う勤務ルール（1日の所定労働時間・標準の休憩時間・月の締め日・残業時間の警告ライン・深夜の時間帯）。
#
# 値だけを持つオブジェクト。管理者が「設定」画面（F6）で保存した値は WorkRuleSetting にあり、
# WorkRules.current がそれを読み込んで返す（まだ保存されていなければ初期値）。
# 勤怠履歴などの計算は WorkRules.current から値を受け取る。
class WorkRules
  # 初期値（所定労働時間 8:00、標準の休憩時間 1:00、月末締め、警告ライン 45時間）
  DEFAULT_SCHEDULED_WORK_MINUTES = 8 * 60
  DEFAULT_STANDARD_BREAK_MINUTES = 60
  DEFAULT_OVERTIME_WARNING_HOURS = 45

  # 深夜時間の時間帯（22:00〜翌5:00）
  NIGHT_START_HOUR = 22
  NIGHT_END_HOUR = 5

  # scheduled_work_minutes … 1日の所定労働時間（分）。これを超えた実働が残業になる
  # standard_break_minutes … 標準の休憩時間（分）。設定として保存するだけで、いまは計算には使わない
  # closing_day            … 月の締め日（15・20・25）。nil は月末締め（1日〜末日）
  # overtime_warning_hours … 月の残業時間の警告ライン（時間）
  attr_reader :scheduled_work_minutes, :standard_break_minutes, :closing_day, :overtime_warning_hours

  def self.current
    WorkRuleSetting.current.to_work_rules
  end

  def initialize(scheduled_work_minutes: DEFAULT_SCHEDULED_WORK_MINUTES,
                 standard_break_minutes: DEFAULT_STANDARD_BREAK_MINUTES,
                 closing_day: nil,
                 overtime_warning_hours: DEFAULT_OVERTIME_WARNING_HOURS)
    @scheduled_work_minutes = scheduled_work_minutes
    @standard_break_minutes = standard_break_minutes
    @closing_day = closing_day
    @overtime_warning_hours = overtime_warning_hours
  end

  def month_end_closing?
    closing_day.nil?
  end

  def overtime_warning_minutes
    overtime_warning_hours * 60
  end

  # 月の残業時間（分）が警告ラインを超えているか（ちょうどは超えていない）
  def overtime_warning?(overtime_minutes)
    overtime_minutes > overtime_warning_minutes
  end

  # date が属する月度
  def period_containing(date)
    AttendancePeriod.containing(date, closing_day: closing_day)
  end

  # 「2026-11」のような文字列から月度を作る。解釈できなければ nil
  def period_from_param(value)
    AttendancePeriod.parse(value, closing_day: closing_day)
  end
end
