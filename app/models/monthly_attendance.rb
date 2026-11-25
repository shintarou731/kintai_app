# ある従業員の1か月（月度）分の勤怠表。月度の初日〜最終日を1日ずつ並べ、合計を出す。
#
# 各日の時間は Attendance の計算（実働・休憩・深夜）をそのまま使うので、ホーム画面と同じ値になる。
# 合計は「日ごとの分」を足し合わせる（日ごとの表示を足した値と必ず一致する）。
# 各日には、公開済みのシフト（予定）と予実比較（ShiftCheck：遅刻・早退・欠勤）も持つ。
# 遅刻・早退・欠勤の回数（#late_count など）は、月次集計（F14）・CSV（F15）でもここから読む。
#
# 締め済み（F14）の月度は、締めた時点の値（MonthlyClosingEntry）から作る ClosedMonthlyAttendance になる。
# 作るときは .for_user / .for_users を使う（月度が締め済みかどうかで、どちらかを返す）。
class MonthlyAttendance
  # 1日分の行
  # status … :none（勤務なし）/ :working（勤務中）/ :on_break（休憩中）/ :finished（退勤済み）/
  #          :missing_clock_out（退勤漏れ：退勤の打刻が無いまま勤務日が過ぎた）
  # clock_out_open … 退勤漏れの日のうち、出勤から24時間以内でまだホーム画面から退勤できる日なら true
  # shift_check    … その日の予実比較（ShiftCheck）。shift は公開済みのシフト（無ければ nil）
  Day = Data.define(:date, :attendance, :status, :worked_minutes, :break_minutes, :overtime_minutes, :night_minutes,
                    :clock_out_open, :shift_check) do
    def worked?
      !attendance.nil?
    end

    def shift
      shift_check.shift
    end

    def scheduled?
      shift_check.scheduled?
    end

    def saturday?
      date.saturday?
    end

    def sunday?
      date.sunday?
    end

    # 日の種類（:holiday / :sunday / :saturday / :weekday）。土曜・日曜の祝日は :holiday（HolidayCalendar）
    def day_kind
      HolidayCalendar.day_kind(date)
    end

    # 祝日名（例：「勤労感謝の日」「振替休日」）。祝日でなければ nil
    def holiday_name
      HolidayCalendar.holiday_name(date)
    end

    def holiday?
      day_kind == :holiday
    end

    # 休日（土日・祝日）か
    def day_off?
      day_kind != :weekday
    end

    def missing_clock_out?
      status == :missing_clock_out
    end

    # 退勤漏れだが、まだホーム画面から退勤を打刻できる日
    def clock_out_open?
      missing_clock_out? && clock_out_open
    end

    # 勤務中・休憩中（時間はまだ確定していない）
    def in_progress?
      %i[working on_break].include?(status)
    end

    # 時間を表示・集計できる日（退勤済みか勤務中）。退勤漏れの日は退勤時刻が無いため数えない
    def countable?
      worked? && !missing_clock_out?
    end

    # 休日（土日・祝日）の勤務時間。勤務日（出勤した日）が休日なら、その日の実働をすべて数える
    # （日付をまたいだ勤務も、ほかの時間と同じく出勤した日に数える）
    def holiday_worked_minutes
      countable? && day_off? ? worked_minutes : 0
    end
  end

  attr_reader :user, :period, :rules, :now

  # 複数の従業員の、同じ月度の勤怠表をまとめて作る（{ user_id => MonthlyAttendance }）。
  # 勤怠・休暇・修正申請・シフトを全員分まとめて読むので、従業員の人数が増えても問い合わせの回数は変わらない
  # （ダッシュボード（F13）・予実の確認（F12）など、全員分を並べる画面で使う）。値は1人ずつ作ったときと同じ。
  # 締め済みの月度なら、締めた時点の値から作る（ClosedMonthlyAttendance）
  def self.for_users(users, period:, rules: WorkRules.current, now: Time.current)
    return ClosedMonthlyAttendance.for_users(users, period: period, now: now) if period.closed?

    users = users.to_a
    ids = users.map(&:id)
    range = period.date_range
    attendances = Attendance.where(user_id: ids, work_date: range).includes(:breaks).group_by(&:user_id)
    leaves = LeaveRequest.where(user_id: ids).blocking.overlapping(period.start_date, period.end_date)
                         .includes(:cancellation_requests).order(:target_date, :id).group_by(&:user_id)
    corrections = AttendanceCorrectionRequest.pending.where(user_id: ids, target_date: range).group_by(&:user_id)
    shifts = Shift.published.where(user_id: ids, work_date: range).group_by(&:user_id)

    users.to_h do |user|
      preloaded = { attendances: attendances.fetch(user.id, []), leaves: leaves.fetch(user.id, []),
                    corrections: corrections.fetch(user.id, []), shifts: shifts.fetch(user.id, []) }
      [ user.id, new(user, period: period, rules: rules, now: now, preloaded: preloaded) ]
    end
  end

  # 1人分の月度の勤怠表（締め済みの月度なら ClosedMonthlyAttendance）
  def self.for_user(user, period:, rules: WorkRules.current, now: Time.current)
    for_users([ user ], period: period, rules: rules, now: now).fetch(user.id)
  end

  # preloaded … for_users がまとめて読んだ、この従業員・この月度の記録（内部用）。nil なら自分で読む
  def initialize(user, period:, rules: WorkRules.current, now: Time.current, preloaded: nil)
    @user = user
    @period = period
    @rules = rules
    @now = now.in_time_zone
    @preloaded = preloaded
  end

  def today
    now.to_date
  end

  def days
    @days ||= period.dates.map { |date| build_day(date, attendances_by_date[date]) }
  end

  # 出勤日数（出勤の打刻がある日。退勤漏れの日も含む）
  def working_days_count
    days.count(&:worked?)
  end

  def total_worked_minutes
    countable_days.sum(&:worked_minutes)
  end

  def total_break_minutes
    countable_days.sum(&:break_minutes)
  end

  def total_overtime_minutes
    countable_days.sum(&:overtime_minutes)
  end

  def total_night_minutes
    countable_days.sum(&:night_minutes)
  end

  # 休日（土日・祝日）の勤務時間の合計
  def total_holiday_worked_minutes
    countable_days.sum(&:holiday_worked_minutes)
  end

  # この月度に取得した有給休暇の日数（休暇の日がこの月度に入る分。休日を除く・半休は 0.5日）
  def paid_leave_days
    leave_day_totals.fetch("paid", 0r)
  end

  # 種類が「欠勤」の承認済み休暇の日数（欠勤の回数には数えないので、別に示す）
  def absence_leave_days
    leave_day_totals.fetch("absence", 0r)
  end

  # 締め済みの月度か（締め済みなら ClosedMonthlyAttendance）
  def closed?
    false
  end

  def closing
    nil
  end

  def missing_clock_out_days
    days.select(&:missing_clock_out?)
  end

  # 予実比較：遅刻・早退・欠勤の回数（その月度の日ごとの印の数）
  def late_count
    days.count { |day| day.shift_check.late? }
  end

  def early_leave_count
    days.count { |day| day.shift_check.early_leave? }
  end

  def absence_count
    days.count { |day| day.shift_check.absent? }
  end

  # 公開済みのシフトがある日数
  def scheduled_days_count
    days.count(&:scheduled?)
  end

  # 印（遅刻・早退・欠勤）が付いた日
  def marked_days
    days.select { |day| day.shift_check.marked? }
  end

  # 退勤漏れの日のうち、まだホーム画面から退勤できる日
  def open_missing_clock_out_days
    missing_clock_out_days.select(&:clock_out_open?)
  end

  # 退勤漏れの日のうち、ホーム画面からは退勤できなくなった日（管理者への連絡が必要）
  def closed_missing_clock_out_days
    missing_clock_out_days.reject(&:clock_out_open?)
  end

  # 勤務中・休憩中の日（合計には表示時点までの時間を含めている）
  def in_progress_day
    days.find(&:in_progress?)
  end

  def current_period?
    period.include?(today)
  end

  # date の承認待ちの打刻修正申請（無ければ nil）。承認されるまで勤怠記録は変わらないので、履歴に「申請中」と示す
  def pending_correction_for(date)
    pending_corrections_by_date[date]
  end

  # 修正申請を出せる日か（今日まで。未来の日は申請できない。締め済みの月度の日も出せない）
  def correctable?(date)
    date <= today && !closed?
  end

  # date にかかる休暇（承認済みで有効なもの、と承認待ちのもの）。開始日の順
  def leaves_on(date)
    leaves.select { |leave| leave.covers?(date) }
  end

  # date に有効な（承認済みの）休暇があるか
  def on_leave?(date)
    leaves_on(date).any?(&:effective?)
  end

  # この月度の承認済みの休暇の日数（種類ごと。休日＝土日・祝日は数えない・半休は 0.5日）。例：{ "paid" => 3/2r }
  # 休日だけの期間の休暇（特別休暇・欠勤）など、日数が0日になる種類も「特別休暇 0日」として出す
  # （勤怠履歴の行に休暇の期間が表示されるのに、月の休暇が「なし」と出て食い違わないように）
  def leave_day_totals
    @leave_day_totals ||= leaves.select(&:effective?)
                                .group_by(&:leave_type)
                                .transform_values { |items| items.sum { |leave| leave.chargeable_days_within(period.date_range) } }
                                .sort_by { |type, _days| LeaveRequest.leave_types.keys.index(type) }
                                .to_h
  end

  # この月度にかかる、承認済みで取り消されていない休暇
  def effective_leaves
    leaves.select(&:effective?)
  end

  # 締めるときに保存する、この月度の日別の値と休暇（MonthlyClosingEntry#snapshot）。
  # 勤怠かシフトがある日だけを持つ（何も無い日は、表示するときに空の日として作る）
  def snapshot_data
    {
      "version" => 1,
      "days" => days.filter_map { |day| day_snapshot(day) if day.worked? || day.scheduled? },
      "leaves" => effective_leaves.map do |leave|
        { "id" => leave.id, "leave_type" => leave.leave_type, "day_part" => leave.day_part,
          "target_date" => leave.target_date.iso8601, "end_date" => leave.end_date.iso8601 }
      end
    }
  end

  private

  def day_snapshot(day)
    attendance = day.attendance
    shift = day.shift
    check = day.shift_check
    {
      "date" => day.date.iso8601, "status" => day.status.to_s,
      "worked" => day.worked_minutes, "break" => day.break_minutes, "overtime" => day.overtime_minutes,
      "night" => day.night_minutes, "holiday_worked" => day.holiday_worked_minutes,
      "attendance" => attendance && {
        "clock_in_at" => attendance.clock_in_at.iso8601, "clock_out_at" => attendance.clock_out_at&.iso8601,
        "breaks" => attendance.breaks.map { |item| [ item.started_at.iso8601, item.ended_at&.iso8601 ] }
      },
      "shift" => shift && {
        "start" => shift.published_start_minute, "end" => shift.published_end_minute, "break" => shift.published_break_minutes,
        "published_at" => shift.published_at&.iso8601, "revised_at" => shift.revised_at&.iso8601
      },
      "marks" => { "late" => check.late_minutes, "early_leave" => check.early_leave_minutes, "absent" => check.absent? }
    }
  end

  def countable_days
    days.select(&:countable?)
  end

  # この月度にかかる、承認済み（取り消されていない）と承認待ちの休暇
  def leaves
    @leaves ||= preloaded(:leaves) do
      user.leave_requests.blocking.overlapping(period.start_date, period.end_date)
          .includes(:cancellation_requests).order(:target_date, :id).to_a
    end
  end

  def pending_corrections_by_date
    @pending_corrections_by_date ||= preloaded(:corrections) do
      user.attendance_correction_requests.pending.where(target_date: period.date_range).to_a
    end.index_by(&:target_date)
  end

  def attendances_by_date
    @attendances_by_date ||= preloaded(:attendances) do
      user.attendances.includes(:breaks).where(work_date: period.date_range).to_a
    end.index_by(&:work_date)
  end

  # 公開済みのシフト（従業員に見せている内容。下書きは使わない）
  def shifts_by_date
    @shifts_by_date ||= preloaded(:shifts) do
      user.shifts.published.where(work_date: period.date_range).to_a
    end.index_by(&:work_date)
  end

  # for_users でまとめて読んだ記録があればそれを、無ければブロックで読んだ記録を返す
  def preloaded(key)
    @preloaded ? @preloaded.fetch(key) : yield
  end

  def shift_check_for(date, attendance)
    ShiftCheck.new(shift: shifts_by_date[date], attendance: attendance,
                   leaves: leaves_on(date).select(&:effective?), now: now)
  end

  def build_day(date, attendance)
    check = shift_check_for(date, attendance)
    unless attendance
      return Day.new(date: date, attendance: nil, status: :none, worked_minutes: 0, break_minutes: 0,
                     overtime_minutes: 0, night_minutes: 0, clock_out_open: false, shift_check: check)
    end

    status = status_of(attendance)
    if status == :missing_clock_out
      return Day.new(date: date, attendance: attendance, status: status, worked_minutes: 0,
                     break_minutes: attendance.finished_break_minutes, overtime_minutes: 0, night_minutes: 0,
                     clock_out_open: attendance.clock_out_open?(as_of: now), shift_check: check)
    end

    Day.new(date: date, attendance: attendance, status: status,
            worked_minutes: attendance.worked_minutes(as_of: now),
            break_minutes: attendance.break_minutes(as_of: now),
            overtime_minutes: attendance.overtime_minutes(scheduled_minutes: rules.scheduled_work_minutes, as_of: now),
            night_minutes: attendance.night_minutes(as_of: now),
            clock_out_open: false, shift_check: check)
  end

  def status_of(attendance)
    if attendance.clocked_out? then :finished
    elsif attendance.missing_clock_out?(as_of: now) then :missing_clock_out
    elsif attendance.on_break? then :on_break
    else :working
    end
  end
end
