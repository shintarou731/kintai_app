require "test_helper"

class MonthlyAttendanceTest < ActiveSupport::TestCase
  setup do
    @user = users(:employee)
    @november = AttendancePeriod.new(year: 2026, month: 11)
  end

  def t(day, hour, min = 0, sec = 0, month: 11)
    Time.zone.local(2026, month, day, hour, min, sec)
  end

  def work(clock_in, clock_out, breaks: [], user: @user)
    record = user.attendances.create!(work_date: clock_in.to_date, clock_in_at: clock_in, clock_out_at: clock_out)
    breaks.each { |from, to| record.breaks.create!(started_at: from, ended_at: to) }
    record
  end

  def monthly(now: t(30, 23), rules: WorkRules.new, period: @november)
    MonthlyAttendance.new(@user, period: period, rules: rules, now: now)
  end

  test "1日〜末日を1日ずつ並べ、勤務の無い日も空の行になる" do
    work(t(2, 9), t(2, 18))
    days = monthly.days
    assert_equal (Date.new(2026, 11, 1)..Date.new(2026, 11, 30)).to_a, days.map(&:date)
    assert days.find { |day| day.date.day == 2 }.worked?
    empty = days.find { |day| day.date.day == 3 }
    assert_not empty.worked?
    assert_equal :none, empty.status
  end

  test "他の人の勤怠や、他の月の勤怠は含めない" do
    work(t(2, 9), t(2, 18), user: users(:admin))
    work(t(31, 9, month: 10), t(31, 18, month: 10))
    work(Time.zone.local(2026, 12, 1, 9), Time.zone.local(2026, 12, 1, 18))
    assert_equal 0, monthly.working_days_count
    assert_equal 0, monthly.total_worked_minutes
  end

  test "合計は日ごとの分を足し、繰り上がりも正しい（7:30 ＋ 8:45 ＝ 16:15）" do
    work(t(2, 9), t(2, 16, 30))            # 7:30
    work(t(3, 9), t(3, 18, 45), breaks: [ [ t(3, 12), t(3, 13) ] ]) # 8:45（残業 0:45）
    result = monthly
    assert_equal 2, result.working_days_count
    assert_equal 16 * 60 + 15, result.total_worked_minutes
    assert_equal 45, result.total_overtime_minutes
    assert_equal 60, result.total_break_minutes
  end

  test "残業は日ごとに所定を超えた分の合計（ある日の不足で別の日の残業は相殺しない）" do
    work(t(2, 9), t(2, 19))  # 10:00 → 残業 2:00
    work(t(3, 9), t(3, 13))  # 4:00 → 残業 0:00
    work(t(4, 9), t(4, 17))  # 8:00（所定ちょうど）→ 残業 0:00
    result = monthly
    assert_equal 120, result.total_overtime_minutes
    assert_equal [ 120, 0, 0 ], result.days.select(&:worked?).map(&:overtime_minutes)
  end

  test "所定労働時間を変えると残業が変わる（F6 で差し替えられるよう rules から受け取る）" do
    work(t(2, 9), t(2, 18), breaks: [ [ t(2, 12), t(2, 13) ] ]) # 8:00
    assert_equal 0, monthly.total_overtime_minutes
    assert_equal 60, monthly(rules: WorkRules.new(scheduled_work_minutes: 7 * 60)).total_overtime_minutes
  end

  test "24時間を超える合計も時間で数える（20日 × 8:01 ＝ 160:20）" do
    (2..21).each { |day| work(t(day, 9), t(day, 17, 1)) }
    result = monthly
    assert_equal 20, result.working_days_count
    assert_equal 160 * 60 + 20, result.total_worked_minutes
    assert_equal 20, result.total_overtime_minutes
  end

  test "深夜時間の合計。日付をまたぐ勤務は出勤した日に数える（月末の夜勤は翌月にずらさない）" do
    work(t(2, 20), t(3, 2), breaks: [ [ t(2, 23, 30), t(3, 0, 30) ] ]) # 深夜 3:00
    work(t(30, 22), Time.zone.local(2026, 12, 1, 6))                  # 深夜 7:00（11/30 の勤務）
    result = monthly(now: Time.zone.local(2026, 12, 1, 12))
    assert_equal 600, result.total_night_minutes
    assert_equal 2, result.working_days_count
    assert_equal 0, MonthlyAttendance.new(@user, period: @november.next, now: Time.zone.local(2026, 12, 1, 12)).working_days_count
  end

  test "実働・休憩はホーム画面と同じ Attendance の計算と一致する" do
    record = work(t(2, 8, 58, 40), t(2, 18, 3, 10), breaks: [ [ t(2, 12, 0, 30), t(2, 12, 59, 59) ] ])
    day = monthly.days.find { |item| item.date.day == 2 }
    assert_equal record.worked_minutes, day.worked_minutes
    assert_equal record.break_minutes, day.break_minutes
  end

  test "退勤の打刻が無いまま過ぎた勤務日は退勤漏れ。時間は合計に含めず、出勤日数には含める" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 5), clock_in_at: t(5, 9))
    work(t(6, 9), t(6, 18))
    result = monthly(now: t(24, 12))
    missing = result.days.find { |day| day.date.day == 5 }
    assert missing.missing_clock_out?
    assert_equal [ Date.new(2026, 11, 5) ], result.missing_clock_out_days.map(&:date)
    assert_equal 2, result.working_days_count
    assert_equal 540, result.total_worked_minutes
  end

  test "勤務日が今日で退勤していない日は勤務中として、表示時点までの時間を数える" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10))
    result = monthly(now: t(10, 23, 59))
    day = result.days.find { |item| item.date.day == 10 }
    assert_equal :working, day.status
    assert_not day.missing_clock_out?
    assert_equal day, result.in_progress_day
    assert_equal 839, day.worked_minutes
    assert_equal 839, result.total_worked_minutes
    assert_empty result.missing_clock_out_days
  end

  test "勤務日が昨日で出勤から24時間以内なら退勤漏れ。合計に含めず、ホームから退勤できる日として扱う" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10))
    result = monthly(now: t(11, 9, 59))
    day = result.days.find { |item| item.date.day == 10 }
    assert_equal :missing_clock_out, day.status
    assert day.clock_out_open?
    assert_nil result.in_progress_day
    assert_equal 1, result.working_days_count
    assert_equal 0, result.total_worked_minutes
    assert_equal 0, result.total_overtime_minutes
    assert_equal 0, result.total_night_minutes
    assert_equal [ day ], result.open_missing_clock_out_days
    assert_empty result.closed_missing_clock_out_days
  end

  test "勤務日が昨日で出勤から24時間を過ぎたら、ホームから退勤できない退勤漏れ" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10))
    result = monthly(now: t(11, 10, 0, 1))
    day = result.days.find { |item| item.date.day == 10 }
    assert_equal :missing_clock_out, day.status
    assert_not day.clock_out_open?
    assert_empty result.open_missing_clock_out_days
    assert_equal [ day ], result.closed_missing_clock_out_days
  end

  test "夜勤で日付をまたいだ勤務中の日も、退勤するまでは退勤漏れ（ホームから退勤できる）" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 23), clock_in_at: t(23, 22))
    result = monthly(now: t(24, 1, 30))
    day = result.days.find { |item| item.date.day == 23 }
    assert_equal :missing_clock_out, day.status
    assert day.clock_out_open?
    assert_equal 0, result.total_worked_minutes
  end

  test "休憩中の日は休憩中として、表示時点までの時間を数える" do
    record = @user.attendances.create!(work_date: Date.new(2026, 11, 24), clock_in_at: t(24, 9))
    record.breaks.create!(started_at: t(24, 12))
    day = monthly(now: t(24, 12, 30)).days.find { |item| item.date.day == 24 }
    assert_equal :on_break, day.status
    assert_equal 30, day.break_minutes
    assert_equal 180, day.worked_minutes
  end

  test "土曜・日曜を判定できる" do
    days = monthly.days
    assert days.find { |day| day.date == Date.new(2026, 11, 7) }.saturday?
    assert days.find { |day| day.date == Date.new(2026, 11, 8) }.sunday?
    assert_not days.find { |day| day.date == Date.new(2026, 11, 9) }.saturday?
  end

  test "祝日を判定できる（祝日名・日の種類）" do
    days = monthly.days.index_by(&:date)
    holiday = days[Date.new(2026, 11, 23)]
    assert holiday.holiday?
    assert holiday.day_off?
    assert_equal :holiday, holiday.day_kind
    assert_equal "勤労感謝の日", holiday.holiday_name
    assert_equal :saturday, days[Date.new(2026, 11, 21)].day_kind
    assert_nil days[Date.new(2026, 11, 24)].holiday_name
    assert_not days[Date.new(2026, 11, 24)].day_off?
  end

  test "今月かどうか" do
    assert monthly(now: t(1, 0)).current_period?
    assert_not monthly(now: Time.zone.local(2026, 12, 1)).current_period?
  end

  test "締め日がある月度では、その範囲の日だけを並べる" do
    rules = WorkRules.new(closing_day: 20)
    period = rules.period_from_param("2026-11")
    work(t(21, 9, month: 10), t(21, 18, month: 10))
    work(t(21, 9), t(21, 18))
    result = monthly(rules: rules, period: period)
    assert_equal Date.new(2026, 10, 21), result.days.first.date
    assert_equal Date.new(2026, 11, 20), result.days.last.date
    assert_equal 1, result.working_days_count
  end
end
