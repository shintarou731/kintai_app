# 管理者の「予実の確認」（F12）：月度（F6 の締め日に従う）ごとの、従業員別の遅刻・早退・欠勤の回数。
#
# - 1人分の値は MonthlyAttendance（勤怠履歴と同じ計算。判定は ShiftCheck）から読むので、本人の勤怠履歴の表示と必ず一致する。
# - 表に出すのは、有効な従業員全員と、その月度に公開済みのシフトか勤怠がある無効な従業員（退職した月の記録も確かめられるように）。
class ShiftReport
  Row = Struct.new(:user, :monthly, keyword_init: true) do
    delegate :late_count, :early_leave_count, :absence_count, :scheduled_days_count, :working_days_count, to: :monthly

    def marks_count
      late_count + early_leave_count + absence_count
    end
  end

  attr_reader :period, :rules, :now

  def initialize(period:, rules: WorkRules.current, now: Time.current)
    @period = period
    @rules = rules
    @now = now
  end

  def rows
    @rows ||= begin
      list = users
      monthlies = MonthlyAttendance.for_users(list, period: period, rules: rules, now: now)
      list.map { |user| Row.new(user: user, monthly: monthlies.fetch(user.id)) }
    end
  end

  def total(key)
    rows.sum(&key)
  end

  # 遅刻・早退・欠勤のどれかがある従業員の数
  def marked_users_count
    rows.count { |row| row.marks_count.positive? }
  end

  private

  def users
    range = period.date_range
    inactive_ids = Shift.published.where(work_date: range).select(:user_id)
    inactive_with_records = User.inactive.where(id: inactive_ids).or(User.inactive.where(id: Attendance.where(work_date: range).select(:user_id)))
    User.active.order(:id).to_a + inactive_with_records.order(:id).to_a
  end
end
