# 締めた月度（MonthlyClosing）の、従業員1人分の値。締めた時点の MonthlyAttendance から作る。
#
# - 列：月次集計の表の項目（出勤日数・総実働・残業・深夜・休日の勤務・有給の取得日数・遅刻/早退/欠勤の回数など）。
#   締めた月度の月次集計の表と CSV（F15）の従業員別集計は、この列をそのまま出す。
# - snapshot：日別の値（打刻・休憩・実働・残業・深夜・休日の勤務・シフト・遅刻/早退/欠勤）と、有効だった休暇（JSON）。
#   締めた月度の日別の勤怠・従業員の勤怠履歴・CSV の日別明細は、ここから ClosedMonthlyAttendance で作る。
# - 日数は 0.5日単位なので、半日の数（half_days）で持つ。
class MonthlyClosingEntry < ApplicationRecord
  belongs_to :monthly_closing, inverse_of: :entries
  belongs_to :user

  serialize :snapshot, coder: JSON

  # 締めた時点の MonthlyAttendance から、保存する値を作る
  def self.attributes_from(monthly)
    {
      user: monthly.user,
      working_days: monthly.working_days_count,
      worked_minutes: monthly.total_worked_minutes,
      overtime_minutes: monthly.total_overtime_minutes,
      night_minutes: monthly.total_night_minutes,
      holiday_worked_minutes: monthly.total_holiday_worked_minutes,
      paid_leave_half_days: (monthly.paid_leave_days * 2).to_i,
      absence_leave_half_days: (monthly.absence_leave_days * 2).to_i,
      scheduled_days: monthly.scheduled_days_count,
      late_count: monthly.late_count,
      early_leave_count: monthly.early_leave_count,
      absence_count: monthly.absence_count,
      missing_clock_out_count: monthly.missing_clock_out_days.size,
      snapshot: monthly.snapshot_data
    }
  end

  def paid_leave_days
    Rational(paid_leave_half_days, 2)
  end

  def absence_leave_days
    Rational(absence_leave_half_days, 2)
  end
end
