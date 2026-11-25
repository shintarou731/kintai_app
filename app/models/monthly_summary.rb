# 管理者の「月次集計」（F14）：ある月度の、従業員ごとの集計（出勤日数・総実働・残業・深夜・休日の勤務・有給の取得日数・
# 遅刻/早退/欠勤の回数）と、締める前に確かめる警告（退勤漏れ・承認待ちの申請）。CSV（F15）もここから読む。
#
# - 未締めの月度：今の記録と今の勤務ルールで計算する（MonthlyAttendance。従業員の勤怠履歴と同じ値）。
# - 締め済みの月度：締めた時点に保存した値（MonthlyClosingEntry）をそのまま出す。表に出す従業員も、締めた時点の顔ぶれ。
#
# 表に出す従業員：有効なユーザー全員（管理者も打刻するので含める）と、その月度に勤怠・公開済みのシフト・承認済みの休暇の
# どれかがある無効なユーザー（退職した月の記録も集計・確定できるように）。記録の無い無効なユーザーは出さない。
class MonthlySummary
  # 1人分の行。値は、締め済みなら保存した値、未締めなら MonthlyAttendance から読む
  class Row
    VALUE_KEYS = %i[working_days_count total_worked_minutes total_overtime_minutes total_night_minutes total_holiday_worked_minutes
                    paid_leave_days absence_leave_days scheduled_days_count late_count early_leave_count absence_count
                    missing_clock_out_count].freeze

    ENTRY_COLUMNS = {
      working_days_count: :working_days, total_worked_minutes: :worked_minutes, total_overtime_minutes: :overtime_minutes,
      total_night_minutes: :night_minutes, total_holiday_worked_minutes: :holiday_worked_minutes, paid_leave_days: :paid_leave_days,
      absence_leave_days: :absence_leave_days, scheduled_days_count: :scheduled_days, late_count: :late_count,
      early_leave_count: :early_leave_count, absence_count: :absence_count, missing_clock_out_count: :missing_clock_out_count
    }.freeze

    attr_reader :user, :monthly, :entry

    def initialize(user:, monthly:, entry: nil)
      @user = user
      @monthly = monthly
      @entry = entry
    end

    VALUE_KEYS.each do |key|
      define_method(key) do
        if entry
          entry.public_send(ENTRY_COLUMNS.fetch(key))
        elsif key == :missing_clock_out_count
          monthly.missing_clock_out_days.size
        else
          monthly.public_send(key)
        end
      end
    end
  end

  attr_reader :period, :rules, :now

  def initialize(period:, rules: WorkRules.current, now: Time.current)
    @period = period
    @rules = rules
    @now = now
  end

  def closed?
    period.closed?
  end

  def closing
    period.closing
  end

  # 計算に使った勤務ルール（締め済みなら締めた時点のルール）
  def effective_rules
    closed? ? closing.rules : rules
  end

  def rows
    @rows ||= closed? ? closed_rows : open_rows
  end

  def total(key)
    rows.sum(&key)
  end

  # 退勤漏れの件数（表の従業員の、この月度の勤務日のうち退勤の打刻が無いもの）
  def missing_clock_out_count
    total(:missing_clock_out_count)
  end

  # この月度にかかる承認待ちの申請（打刻修正・休暇・休暇の取消）
  def pending_requests
    @pending_requests ||= begin
      range = period.date_range
      corrections = AttendanceCorrectionRequest.pending.where(target_date: range)
      leaves = LeaveRequest.pending.overlapping(period.start_date, period.end_date)
      cancellations = LeaveCancellationRequest.pending.where(leave_request_id: LeaveRequest.overlapping(period.start_date, period.end_date).select(:id))
      ApprovalRequest.where(id: corrections.select(:id)).or(ApprovalRequest.where(id: leaves.select(:id)))
                     .or(ApprovalRequest.where(id: cancellations.select(:id)))
                     .includes(:user).oldest_first.to_a
    end
  end

  # 承認待ちの申請の件数（種類ごと。{ "打刻修正" => 2, "休暇" => 1 }）
  def pending_counts_by_kind
    pending_requests.group_by(&:kind_label).transform_values(&:size)
  end

  def warnings?
    missing_clock_out_count.positive? || pending_requests.any?
  end

  # 有給の取得日数などに「欠勤」の休暇があるか（欠勤の回数には含めない旨を表に添える）
  def absence_leaves?
    rows.any? { |row| row.absence_leave_days.positive? }
  end

  private

  def open_rows
    list = users
    monthlies = MonthlyAttendance.for_users(list, period: period, rules: rules, now: now)
    list.map { |user| Row.new(user: user, monthly: monthlies.fetch(user.id)) }
  end

  def closed_rows
    entries = closing.entries.includes(:user).to_a
    list = entries.map(&:user)
    monthlies = ClosedMonthlyAttendance.for_users(list, period: period, now: now)
    entries.map { |entry| Row.new(user: entry.user, monthly: monthlies.fetch(entry.user_id), entry: entry) }
  end

  def users
    range = period.date_range
    with_records = Attendance.where(work_date: range).select(:user_id)
    with_shifts = Shift.published.where(work_date: range).select(:user_id)
    with_leaves = LeaveRequest.effective.overlapping(period.start_date, period.end_date).select(:user_id)
    inactive = User.inactive.where(id: with_records).or(User.inactive.where(id: with_shifts)).or(User.inactive.where(id: with_leaves))
    User.active.order(:id).to_a + inactive.order(:id).to_a
  end
end
