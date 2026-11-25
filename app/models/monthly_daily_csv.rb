# 日別明細の CSV（F15）：その月度の全従業員の、1日1行の勤怠（従業員の順に、月度の初日〜最終日）。
#
# - 出す従業員は月次集計の表と同じ（MonthlySummary#rows）。値は各行の勤怠表（MonthlyAttendance#days）から読むので、
#   勤怠履歴・日別の勤怠の画面と同じ値になる。締め済みの月度は、締めた時点に固定した日別の値（ClosedMonthlyAttendance）
# - 勤務の無い日の行も出す（画面の勤怠履歴と同じく、月度のすべての日を並べる。休暇・欠勤の日を拾いやすく、
#   従業員ごとの行数がそろうため）。勤務の無い日は、出勤〜深夜の欄が空欄
# - 退勤漏れの日：退勤は「未打刻」、時間の欄は空欄（画面の「—」。時間を計算できないため）、状態は「退勤漏れ」
# - 勤務中・休憩中の日：書き出した時点までの時間（画面と同じ）。退勤は空欄、状態は「勤務中」「休憩中」
# - 日付をまたいで退勤した日は、退勤に「翌」を付ける（画面と同じ。例「翌02:00」）
# 書き方の決まり（BOM・改行・エスケープ・数式の扱い）は AttendanceCsv。
class MonthlyDailyCsv
  HEADER = [
    "従業員ID", "従業員名", "日付", "曜日", "休日", "予定（シフト）", "出勤", "退勤",
    "休憩", "休憩（分）", "実働", "実働（分）", "残業", "残業（分）", "深夜", "深夜（分）",
    "休暇", "遅刻・早退・欠勤", "遅刻（分）", "早退（分）", "状態"
  ].freeze

  WEEKDAYS = %w[日 月 火 水 木 金 土].freeze
  STATUS_LABELS = { working: "勤務中", on_break: "休憩中", missing_clock_out: "退勤漏れ" }.freeze
  MARK_LABELS = { late: "遅刻", early_leave: "早退", absent: "欠勤" }.freeze

  attr_reader :summary

  def initialize(summary)
    @summary = summary
  end

  def filename
    "勤怠明細_#{AttendanceCsv.period_file_label(summary.period)}.csv"
  end

  # ASCII だけの予備のファイル名（例：「kintai_daily_2026-11.csv」）
  def ascii_filename
    "kintai_daily_#{AttendanceCsv.period_ascii_label(summary.period)}.csv"
  end

  def to_csv
    rows = summary.rows.flat_map do |row|
      monthly = row.monthly
      monthly.days.map { |day| values(row.user, monthly, day) }
    end
    AttendanceCsv.generate(HEADER, rows)
  end

  private

  def values(user, monthly, day)
    check = day.shift_check
    [
      user.id, user.name, AttendanceCsv.date(day.date), WEEKDAYS[day.date.wday], day_off_label(day),
      day.shift&.published_range_label, AttendanceCsv.clock(day.attendance&.clock_in_at), clock_out(day),
      *minutes_pair(day, day.break_minutes), *minutes_pair(day, day.worked_minutes),
      *minutes_pair(day, day.overtime_minutes), *minutes_pair(day, day.night_minutes),
      monthly.leaves_on(day.date).map { |leave| leave.label_on(day.date) }.join("、").presence,
      marks_label(check), (check.late_minutes if check.late?), (check.early_leave_minutes if check.early_leave?),
      STATUS_LABELS[day.status]
    ]
  end

  # 休日の欄：祝日なら祝日名、祝日ではない土日は「土曜」「日曜」、平日は空欄
  def day_off_label(day)
    day.holiday_name || { saturday: "土曜", sunday: "日曜" }[day.day_kind]
  end

  def clock_out(day)
    attendance = day.attendance
    return if attendance.nil?
    return "未打刻" if day.missing_clock_out?
    return unless attendance.clocked_out?

    next_day = attendance.clock_out_at.in_time_zone.to_date > day.date
    "#{'翌' if next_day}#{AttendanceCsv.clock(attendance.clock_out_at)}"
  end

  # 時間の2列（「7:45」と 465）。勤務の無い日・退勤漏れの日は空欄（画面の空欄・「—」と同じ）
  def minutes_pair(day, minutes)
    return [ nil, nil ] unless day.countable?

    [ AttendanceCsv.duration(minutes), minutes.to_i ]
  end

  # 遅刻・早退・欠勤の印（画面のバッジと同じ書き方。例「遅刻 0:05、早退 0:10」「欠勤」）
  def marks_label(check)
    check.marks.map do |mark|
      minutes = { late: check.late_minutes, early_leave: check.early_leave_minutes }[mark]
      minutes ? "#{MARK_LABELS.fetch(mark)} #{AttendanceCsv.duration(minutes)}" : MARK_LABELS.fetch(mark)
    end.join("、").presence
  end
end
