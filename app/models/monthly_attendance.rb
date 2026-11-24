# ある従業員の1か月（月度）分の勤怠表。月度の初日〜最終日を1日ずつ並べ、合計を出す。
#
# 各日の時間は Attendance の計算（実働・休憩・深夜）をそのまま使うので、ホーム画面と同じ値になる。
# 合計は「日ごとの分」を足し合わせる（日ごとの表示を足した値と必ず一致する）。
class MonthlyAttendance
  # 1日分の行
  # status … :none（勤務なし）/ :working（勤務中）/ :on_break（休憩中）/ :finished（退勤済み）/
  #          :missing_clock_out（退勤漏れ：退勤の打刻が無いまま勤務日が過ぎた）
  # clock_out_open … 退勤漏れの日のうち、出勤から24時間以内でまだホーム画面から退勤できる日なら true
  Day = Data.define(:date, :attendance, :status, :worked_minutes, :break_minutes, :overtime_minutes, :night_minutes,
                    :clock_out_open) do
    def worked?
      !attendance.nil?
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
  end

  attr_reader :user, :period, :rules, :now

  def initialize(user, period:, rules: WorkRules.current, now: Time.current)
    @user = user
    @period = period
    @rules = rules
    @now = now.in_time_zone
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

  def missing_clock_out_days
    days.select(&:missing_clock_out?)
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

  # 修正申請を出せる日か（今日まで。未来の日は申請できない）
  def correctable?(date)
    date <= today
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
  def leave_day_totals
    @leave_day_totals ||= leaves.select(&:effective?)
                                .group_by(&:leave_type)
                                .transform_values { |items| items.sum { |leave| leave.chargeable_days_within(period.date_range) } }
                                .reject { |_type, days| days.zero? }
                                .sort_by { |type, _days| LeaveRequest.leave_types.keys.index(type) }
                                .to_h
  end

  private

  def countable_days
    days.select(&:countable?)
  end

  # この月度にかかる、承認済み（取り消されていない）と承認待ちの休暇
  def leaves
    @leaves ||= user.leave_requests.blocking.overlapping(period.start_date, period.end_date)
                    .includes(:cancellation_requests).order(:target_date, :id).to_a
  end

  def pending_corrections_by_date
    @pending_corrections_by_date ||= user.attendance_correction_requests.pending
                                         .where(target_date: period.date_range)
                                         .index_by(&:target_date)
  end

  def attendances_by_date
    @attendances_by_date ||= user.attendances.includes(:breaks)
                                 .where(work_date: period.date_range)
                                 .index_by(&:work_date)
  end

  def build_day(date, attendance)
    return Day.new(date: date, attendance: nil, status: :none, worked_minutes: 0, break_minutes: 0,
                   overtime_minutes: 0, night_minutes: 0, clock_out_open: false) unless attendance

    status = status_of(attendance)
    if status == :missing_clock_out
      return Day.new(date: date, attendance: attendance, status: status, worked_minutes: 0,
                     break_minutes: attendance.finished_break_minutes, overtime_minutes: 0, night_minutes: 0,
                     clock_out_open: attendance.clock_out_open?(as_of: now))
    end

    Day.new(date: date, attendance: attendance, status: status,
            worked_minutes: attendance.worked_minutes(as_of: now),
            break_minutes: attendance.break_minutes(as_of: now),
            overtime_minutes: attendance.overtime_minutes(scheduled_minutes: rules.scheduled_work_minutes, as_of: now),
            night_minutes: attendance.night_minutes(as_of: now),
            clock_out_open: false)
  end

  def status_of(attendance)
    if attendance.clocked_out? then :finished
    elsif attendance.missing_clock_out?(as_of: now) then :missing_clock_out
    elsif attendance.on_break? then :on_break
    else :working
    end
  end
end
