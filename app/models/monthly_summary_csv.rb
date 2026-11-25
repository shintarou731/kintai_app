# 月次集計の CSV（F15）：その月度の従業員別の集計（月次集計の表と同じ項目）。1人1行。
#
# 値は MonthlySummary の行から読む（画面の表と同じ値。締め済みの月度は締めた時点に固定した値）。
# 時間は「時:分」と「分」の2列、有給などの日数は数値（0.5日単位）、回数は数値で出す。
# 書き方の決まり（BOM・改行・エスケープ・数式の扱い）は AttendanceCsv。
class MonthlySummaryCsv
  HEADER = [
    "月度", "期間", "締め", "従業員ID", "氏名", "アカウント",
    "出勤日数", "総実働", "総実働（分）", "残業", "残業（分）", "深夜", "深夜（分）", "休日勤務", "休日勤務（分）",
    "有給取得（日）", "遅刻（回）", "早退（回）", "欠勤（回）", "欠勤の休暇（日）", "退勤漏れ（件）"
  ].freeze

  attr_reader :summary

  def initialize(summary)
    @summary = summary
  end

  def filename
    "勤怠集計_#{AttendanceCsv.period_file_label(summary.period)}.csv"
  end

  # ASCII だけの予備のファイル名（例：「kintai_summary_2026-11.csv」）
  def ascii_filename
    "kintai_summary_#{AttendanceCsv.period_ascii_label(summary.period)}.csv"
  end

  def to_csv
    AttendanceCsv.generate(HEADER, summary.rows.map { |row| values(row) })
  end

  private

  def values(row)
    period = summary.period
    user = row.user
    [
      period.label, "#{AttendanceCsv.date(period.start_date)}〜#{AttendanceCsv.date(period.end_date)}", summary.closed? ? "締め済み" : "未締め",
      user.id, user.name, user.active? ? "有効" : "無効",
      row.working_days_count,
      *minutes_pair(row.total_worked_minutes), *minutes_pair(row.total_overtime_minutes),
      *minutes_pair(row.total_night_minutes), *minutes_pair(row.total_holiday_worked_minutes),
      AttendanceCsv.days(row.paid_leave_days), row.late_count, row.early_leave_count, row.absence_count,
      AttendanceCsv.days(row.absence_leave_days), row.missing_clock_out_count
    ]
  end

  def minutes_pair(minutes)
    [ AttendanceCsv.duration(minutes), minutes.to_i ]
  end
end
