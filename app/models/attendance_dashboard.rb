# 管理者のダッシュボード（F13）：今日の全員の状態と、対応が必要な事項（承認待ち・退勤漏れ・残業の警告）。
#
# 対象は有効なユーザー全員（従業員と管理者。管理者も打刻するため）。並びは ID の順。
# 従業員の人数によらず、問い合わせの回数が一定になるよう、全員分の記録をまとめて読む。
#
# 今日の状態（Row#state）。上から順に当てはまるものにする
# 1. :working / :on_break … 退勤していない勤務がある（ホーム画面の打刻と同じ基準：TimeClock#current_attendance）。
#                           前日から日付をまたいで勤務中の人も、ここに入る（Row#overnight? で「前日 22:00 出勤」と出す）
# 2. :finished            … 今日を勤務日とする勤務があり、退勤済み
# 3. :not_started（遅れ） … シフトの開始時刻を過ぎても出勤していない（ShiftCheck の :not_clocked_in。シフトの終了も過ぎた
#                           :absent も含む）。前日に始まって日付をまたぐシフトの途中（0:30 に見た 22:00〜翌6:00）も判定する
# 4. :on_leave            … 承認済みの全日の休暇、半休でシフトの時間がすべて埋まる日、または半休の時間帯の最中
#                           （午前半休は 0:00〜12:00、午後半休は 13:00〜。HalfDayLeaveWindow）で、まだ打刻していない
# 5. :finished            … 前日に出勤し、今日の0:00以降に退勤した（夜勤明け。今日はまだ出勤していない）
# 6. :not_started         … それ以外
# 実際の打刻（1・2）は休暇より優先する（休暇の日に出勤した人は「勤務中」と出し、休暇のバッジを添える）。
class AttendanceDashboard
  STATES = %i[working on_break finished not_started on_leave].freeze

  # 残業の警告：今月度の残業が、警告ライン（F6）のこの割合を超えた従業員を出す
  OVERTIME_ALERT_RATIO = Rational(4, 5)

  # ShiftCheck の状態のうち「未出勤（遅れ）」にするもの
  LATE_STATUSES = %i[not_clocked_in absent].freeze

  # 1人分の行
  # date             … 今日
  # attendance       … 表に出す勤務（勤務中の勤務 → 今日の勤務 → 今日退勤した前日の勤務 の順）。無ければ nil
  # today_check      … 今日のシフトの予実（ShiftCheck）
  # previous_check   … 前日に始まり、まだ終わっていない日付をまたぐシフトの予実（無ければ nil）
  # leaves           … 今日にかかる承認済みの休暇
  Row = Data.define(:user, :date, :state, :late, :attendance, :today_check, :previous_check, :leaves) do
    def late?
      late
    end

    def shift
      today_check.shift
    end

    def previous_shift
      previous_check&.shift
    end

    # 遅れの判定に使ったシフトの予実（今日のシフト、または前日からのシフト）
    def late_check
      return unless late?

      LATE_STATUSES.include?(today_check.status) ? today_check : previous_check
    end

    # 表に出す勤務が、前日を勤務日とする勤務か（日付をまたいで勤務中・夜勤明け）
    def overnight?
      !attendance.nil? && attendance.work_date != date
    end
  end

  # 残業の警告の1行
  OvertimeRow = Data.define(:user, :overtime_minutes, :warning_minutes) do
    def over_warning?
      overtime_minutes > warning_minutes
    end

    # 警告ラインに対する割合（%。切り捨て）
    def percentage
      warning_minutes.positive? ? (overtime_minutes * 100 / warning_minutes) : 0
    end
  end

  attr_reader :admin, :rules, :now

  def initialize(admin:, rules: WorkRules.current, now: Time.current)
    @admin = admin
    @rules = rules
    @now = now.in_time_zone
  end

  def today
    now.to_date
  end

  def users
    @users ||= User.active.order(:id).to_a
  end

  def rows
    @rows ||= users.map { |user| build_row(user) }
  end

  # 表の並び：遅れの人 → 勤務中 → 休憩中 → 未出勤 → 退勤済み → 休暇。同じ状態の中は ID の順
  def sorted_rows
    order = %i[working on_break not_started finished on_leave]
    rows.each_with_index.sort_by { |row, index| [ row.late? ? 0 : 1, order.index(row.state), index ] }.map(&:first)
  end

  # 状態ごとの人数（{ working: 2, on_break: 0, ... }）
  def counts
    @counts ||= STATES.index_with { |state| rows.count { |row| row.state == state } }
  end

  def late_count
    rows.count(&:late?)
  end

  # ---- 対応が必要な事項 ----

  # この管理者が処理できる承認待ちの申請（ナビのバッジと同じ数え方：ApprovalRequest.actionable_by）
  def actionable_approval_count
    @actionable_approval_count ||= ApprovalRequest.actionable_by(admin, active_admin_count: active_admin_count).count
  end

  # 承認待ちの申請の全件（自分の申請で、他の管理者が処理するものを含む）
  def pending_approval_count
    @pending_approval_count ||= ApprovalRequest.pending.count
  end

  # 前日以前の退勤漏れ（MissingClockOutList と同じ数え方）
  def missing_clock_outs
    @missing_clock_outs ||= MissingClockOutList.new(now: now)
  end

  # 今月度
  def period
    @period ||= rules.period_containing(today)
  end

  # 残業の警告ラインの 80%（分）。これを超えた従業員を出す
  def overtime_alert_minutes
    rules.overtime_warning_minutes * OVERTIME_ALERT_RATIO
  end

  # 今月度の残業が警告ラインの 80% を超えた従業員（残業の多い順）。値は勤怠履歴（MonthlyAttendance）と同じ
  def overtime_rows
    @overtime_rows ||= begin
      monthlies = MonthlyAttendance.for_users(users, period: period, rules: rules, now: now)
      users.filter_map do |user|
        minutes = monthlies.fetch(user.id).total_overtime_minutes
        OvertimeRow.new(user: user, overtime_minutes: minutes, warning_minutes: rules.overtime_warning_minutes) if minutes > overtime_alert_minutes
      end.sort_by { |row| [ -row.overtime_minutes, row.user.id ] }
    end
  end

  private

  def active_admin_count
    @active_admin_count ||= User.active_admins.count
  end

  def user_ids
    users.map(&:id)
  end

  def yesterday
    today - 1
  end

  # 前日・今日を勤務日とする勤務（{ user_id => { date => Attendance } }）
  def attendances
    @attendances ||= Attendance.where(user_id: user_ids, work_date: yesterday..today).includes(:breaks)
                               .group_by(&:user_id).transform_values { |items| items.index_by(&:work_date) }
  end

  # 前日・今日の公開済みのシフト
  def shifts
    @shifts ||= Shift.published.where(user_id: user_ids, work_date: yesterday..today)
                     .group_by(&:user_id).transform_values { |items| items.index_by(&:work_date) }
  end

  # 前日・今日にかかる、承認済みで取り消されていない休暇
  def leaves
    @leaves ||= LeaveRequest.effective.where(user_id: user_ids).overlapping(yesterday, today)
                            .order(:target_date, :id).group_by(&:user_id)
  end

  def leaves_for(user, date)
    leaves.fetch(user.id, []).select { |leave| leave.covers?(date) }
  end

  # ホーム画面から退勤できる、退勤していない勤務（TimeClock#current_attendance と同じ基準）
  def current_attendance_for(by_date)
    earliest = TimeClock.earliest_open_clock_in(now)
    by_date.values.select { |item| !item.clocked_out? && item.clock_in_at >= earliest && item.clock_in_at <= now }
           .max_by(&:clock_in_at)
  end

  def build_row(user)
    by_date = attendances.fetch(user.id, {})
    user_shifts = shifts.fetch(user.id, {})
    today_leaves = leaves_for(user, today)
    today_check = ShiftCheck.new(shift: user_shifts[today], attendance: by_date[today], leaves: today_leaves, now: now)
    previous_check = previous_check_for(user, user_shifts[yesterday], by_date[yesterday])

    current = current_attendance_for(by_date)
    today_attendance = by_date[today]
    previous = by_date[yesterday]
    previous_finished_today = previous if previous&.clocked_out? && previous.clock_out_at.in_time_zone.to_date == today

    state, late, shown =
      if current
        [ current.on_break? ? :on_break : :working, false, current ]
      elsif today_attendance
        [ :finished, false, today_attendance ]
      elsif late?(today_check, previous_check)
        [ :not_started, true, previous_finished_today ]
      elsif on_leave?(today_check, today_leaves)
        [ :on_leave, false, previous_finished_today ]
      elsif previous_finished_today
        [ :finished, false, previous_finished_today ]
      else
        [ :not_started, false, nil ]
      end

    Row.new(user: user, date: today, state: state, late: late, attendance: shown, today_check: today_check,
            previous_check: previous_check, leaves: today_leaves)
  end

  # 前日に始まり、まだ終わっていない日付をまたぐシフト（例：0:30 に見た 22:00〜翌6:00）の予実
  def previous_check_for(user, shift, attendance)
    return unless shift && shift.published_ends_at > now

    ShiftCheck.new(shift: shift, attendance: attendance, leaves: leaves_for(user, yesterday), now: now)
  end

  def late?(today_check, previous_check)
    LATE_STATUSES.include?(today_check.status) || previous_check&.status == :not_clocked_in
  end

  def on_leave?(today_check, today_leaves)
    return true if today_check.status == :on_leave
    return true if today_leaves.any?(&:full_day?)

    today_leaves.select(&:half_day?).any? { |leave| HalfDayLeaveWindow.range(leave, today).cover?(now) }
  end
end
