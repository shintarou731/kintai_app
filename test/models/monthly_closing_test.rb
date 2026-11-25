require "test_helper"

# 月度の締め（F14）：締めた時点の期間・値で固定する／勤務ルールを変えても変わらない／解除すると今のルールで計算し直す
class MonthlyClosingTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # 2026-12-05（土）10:00。11月は終わっている
  NOW = Time.zone.local(2026, 12, 5, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    @inactive = users(:inactive_employee)
  end

  teardown { travel_back }

  def at(date, hour, minute = 0)
    Time.zone.local(date.year, date.month, date.day, hour, minute)
  end

  def work!(user, date, from, to, breaks: [])
    attendance = Attendance.create!(user: user, work_date: date, clock_in_at: at(date, *from), clock_out_at: to && at(date, *to))
    breaks.each { |(s, e)| attendance.breaks.create!(started_at: at(date, *s), ended_at: at(date, *e)) }
    attendance
  end

  def set_rules!(**values)
    setting = WorkRuleSetting.current
    values.each { |key, value| setting.public_send(:"#{key}=", value) }
    setting.save!
  end

  def close!(year = 2026, month = 11)
    MonthlyClosing.close!(year: year, month: month, by: @admin, now: Time.current)
  end

  def monthly(user, param = "2026-11")
    rules = WorkRules.current
    MonthlyAttendance.for_user(user, period: rules.period_from_param(param), rules: rules, now: Time.current)
  end

  def row(user, param = "2026-11")
    rules = WorkRules.current
    MonthlySummary.new(period: rules.period_from_param(param), rules: rules, now: Time.current).rows.find { |item| item.user == user }
  end

  def day(monthly, date)
    monthly.days.find { |item| item.date == date }
  end

  test "締めると、期間・その時点の勤務ルール・従業員ごとの集計値と日別の値を保存する" do
    work!(@employee, Date.new(2026, 11, 10), [ 9, 0 ], [ 19, 0 ], breaks: [ [ [ 12, 0 ], [ 13, 0 ] ] ]) # 実働 9:00
    work!(@employee, Date.new(2026, 11, 21), [ 22, 0 ], nil).update!(clock_out_at: at(Date.new(2026, 11, 22), 2, 0)) # 土曜・深夜 4:00
    Attendance.create!(user: @employee, work_date: Date.new(2026, 11, 26), clock_in_at: at(Date.new(2026, 11, 26), 9, 0)) # 退勤漏れ

    closing = close!
    assert_equal [ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ], [ closing.start_date, closing.end_date ]
    assert_equal [ 480, 60, nil, 45 ], [ closing.scheduled_work_minutes, closing.standard_break_minutes, closing.closing_day, closing.overtime_warning_hours ]
    assert_equal @admin, closing.closed_by
    assert_equal "2026年11月", closing.label

    entry = closing.entries.find_by!(user: @employee)
    assert_equal 3, entry.working_days
    assert_equal 13 * 60, entry.worked_minutes
    assert_equal 60, entry.overtime_minutes
    assert_equal 4 * 60, entry.night_minutes
    assert_equal 4 * 60, entry.holiday_worked_minutes
    assert_equal 1, entry.missing_clock_out_count
    days = entry.snapshot["days"].index_by { |data| data["date"] }
    assert_equal({ "worked" => 540, "overtime" => 60, "night" => 0, "status" => "finished" },
                 days["2026-11-10"].slice("worked", "overtime", "night", "status"))
    assert_equal "missing_clock_out", days["2026-11-26"]["status"]
    # 記録の無い無効なユーザーは表に入れない。有効なユーザーは記録が無くても入れる
    assert_equal [ @admin.id, @employee.id ], closing.entries.map(&:user_id)
  end

  test "締めた月度は、所定労働時間を変えても値が変わらない（所定8:00で締め、7:00に変えても実働8:00の日の残業は0:00のまま）" do
    date = Date.new(2026, 11, 10)
    work!(@employee, date, [ 9, 0 ], [ 18, 0 ], breaks: [ [ [ 12, 0 ], [ 13, 0 ] ] ]) # 実働 8:00
    work!(@employee, Date.new(2026, 12, 1), [ 9, 0 ], [ 18, 0 ], breaks: [ [ [ 12, 0 ], [ 13, 0 ] ] ])
    close!

    set_rules!(scheduled_work_time: "7:00", overtime_warning_hours: 1)
    closed = monthly(@employee)
    assert closed.closed?
    assert_equal 0, day(closed, date).overtime_minutes
    assert_equal 480, day(closed, date).worked_minutes
    assert_equal 0, closed.total_overtime_minutes
    assert_equal 480, closed.rules.scheduled_work_minutes
    assert_equal 45, closed.rules.overtime_warning_hours
    assert_equal 0, row(@employee).total_overtime_minutes
    # 未締めの12月は今のルールで計算する
    assert_equal 60, monthly(@employee, "2026-12").total_overtime_minutes
  end

  test "締めた月度は、締め日を変えても期間が変わらない。となりの月度は重なり・すき間が出ないように決まる" do
    set_rules!(closing_day: 20)
    rules = WorkRules.current
    assert_equal [ Date.new(2026, 10, 21), Date.new(2026, 11, 20) ], [ rules.period_from_param("2026-11").start_date, rules.period_from_param("2026-11").end_date ]
    close!

    set_rules!(closing_day: "")
    rules = WorkRules.current
    november = rules.period_from_param("2026-11")
    december = rules.period_from_param("2026-12")
    october = rules.period_from_param("2026-10")
    assert_equal [ Date.new(2026, 10, 21), Date.new(2026, 11, 20) ], [ november.start_date, november.end_date ]
    assert_equal [ Date.new(2026, 11, 21), Date.new(2026, 12, 31) ], [ december.start_date, december.end_date ]
    assert_equal [ Date.new(2026, 10, 1), Date.new(2026, 10, 20) ], [ october.start_date, october.end_date ]
    assert_equal "2026-12", rules.period_containing(Date.new(2026, 11, 25)).to_param

    set_rules!(closing_day: 15)
    december = WorkRules.current.period_from_param("2026-12")
    assert_equal [ Date.new(2026, 11, 21), Date.new(2026, 12, 15) ], [ december.start_date, december.end_date ]
  end

  test "解除すると、今の勤務ルールで期間と値を計算し直し、もう一度締めるとその時点の値で固定し直す" do
    date = Date.new(2026, 11, 10)
    work!(@employee, date, [ 9, 0 ], [ 18, 0 ], breaks: [ [ [ 12, 0 ], [ 13, 0 ] ] ])
    work!(@employee, Date.new(2026, 11, 25), [ 9, 0 ], [ 18, 0 ], breaks: [ [ [ 12, 0 ], [ 13, 0 ] ] ])
    set_rules!(closing_day: 20)
    first = close!
    set_rules!(closing_day: "", scheduled_work_time: "7:00")
    assert_equal 0, monthly(@employee).total_overtime_minutes

    first.reopen!(by: @admin, now: Time.current)
    assert_equal @admin, first.reload.reopened_by
    assert_equal NOW, first.reopened_at
    reopened = monthly(@employee)
    assert_not reopened.closed?
    # 期間は今の締め日（月末）で 11/1〜11/30 になり、11/25 も入る。残業は所定 7:00 で 1:00 ×2
    assert_equal [ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ], [ reopened.period.start_date, reopened.period.end_date ]
    assert_equal 120, reopened.total_overtime_minutes

    second = close!
    assert_equal 2, MonthlyClosing.where(year: 2026, month: 11).count
    assert_equal second, MonthlyClosing.active.find_by(year: 2026, month: 11)
    set_rules!(scheduled_work_time: "8:00")
    assert_equal 120, monthly(@employee).total_overtime_minutes
    assert_equal 60, day(monthly(@employee), date).overtime_minutes
    assert_equal 480 + 480, second.entries.find_by!(user: @employee).worked_minutes
  end

  test "締めた後に解除済みの締めを解除しようとするとエラー" do
    closing = close!
    closing.reopen!(by: @admin)
    error = assert_raises(MonthlyClosing::Error) { closing.reopen!(by: @admin) }
    assert_match "すでに", error.message
  end

  test "締め済みの月度は二重に締められない。期間が終わっていない月度は締められない" do
    close!
    assert_raises(MonthlyClosing::Error, match: /すでに締め済み/) { close! }
    error = assert_raises(MonthlyClosing::Error) { close!(2026, 12) }
    assert_match "まだ終わっていない", error.message
    assert_equal 1, MonthlyClosing.count
  end

  test "管理者でなければ締められない" do
    assert_raises(MonthlyClosing::Error) { MonthlyClosing.close!(year: 2026, month: 11, by: @employee) }
  end

  test "締めた後に打刻・休暇・シフトが画面と同じ値で表示される（保存した日別の値から作る）" do
    date = Date.new(2026, 11, 16)
    shift = Shift.create!(user: @employee, work_date: date, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    shift.publish_draft!(now: Time.zone.local(2026, 11, 10, 9))
    work!(@employee, date, [ 9, 12 ], [ 17, 0 ])
    leave = LeaveRequest.new(user: @employee, leave_type: "paid", target_date: Date.new(2026, 11, 17), end_date: Date.new(2026, 11, 17),
                             reason: "私用", status: "approved")
    leave.save!(validate: false)
    live = monthly(@employee)
    close!

    closed = monthly(@employee)
    assert_kind_of ClosedMonthlyAttendance, closed
    %i[working_days_count total_worked_minutes total_overtime_minutes total_night_minutes total_holiday_worked_minutes
       paid_leave_days late_count early_leave_count absence_count scheduled_days_count].each do |key|
      assert_equal live.public_send(key), closed.public_send(key), key
    end
    assert_equal live.days.map { |item| [ item.date, item.shift_check.marks, item.worked_minutes ] },
                 closed.days.map { |item| [ item.date, item.shift_check.marks, item.worked_minutes ] }
    assert_equal [ "有給（全日）" ], closed.leaves_on(Date.new(2026, 11, 17)).map(&:day_label)
    assert_equal 1r, row(@employee).paid_leave_days

    # 締めた後にシフトを変えても、締めた月度の遅刻・早退は変わらない
    shift.update!(start_time: "10:00", end_time: "17:00")
    shift.publish_draft!(now: Time.current)
    assert_equal [ :late, :early_leave ], day(monthly(@employee), date).shift_check.marks
    assert_equal 1, row(@employee).late_count
  end

  test "記録のある無効なユーザーは表に入り、記録の無い無効なユーザーは入らない" do
    assert_not_includes MonthlySummary.new(period: WorkRules.current.period_from_param("2026-11")).rows.map(&:user), @inactive
    work!(@inactive, Date.new(2026, 11, 2), [ 9, 0 ], [ 17, 0 ])
    users = MonthlySummary.new(period: WorkRules.current.period_from_param("2026-11")).rows.map(&:user)
    assert_equal @inactive, users.last
  end
end
