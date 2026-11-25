require "test_helper"

class AttendanceTest < ActiveSupport::TestCase
  def build_attendance(**attrs)
    users(:employee).attendances.build({ work_date: Date.new(2026, 11, 24), clock_in_at: Time.zone.local(2026, 11, 24, 9, 0) }.merge(attrs))
  end

  test "勤務日と出勤時刻は必須" do
    attendance = Attendance.new(user: users(:employee))
    assert_not attendance.valid?
    assert attendance.errors[:work_date].any?
    assert attendance.errors[:clock_in_at].any?
  end

  test "同じ人の同じ勤務日は1件まで" do
    build_attendance.save!
    duplicate = build_attendance
    assert_not duplicate.valid?
    assert_includes duplicate.errors.full_messages, "勤務日はすでに出勤の記録があります"

    assert users(:admin).attendances.build(work_date: Date.new(2026, 11, 24), clock_in_at: Time.current).valid?
  end

  test "退勤時刻は出勤時刻より前にできない" do
    attendance = build_attendance(clock_out_at: Time.zone.local(2026, 11, 24, 8, 59))
    assert_not attendance.valid?
    assert_includes attendance.errors.full_messages, "退勤時刻は出勤時刻より後にしてください"
  end

  test "実働時間は出勤から退勤まで（分単位の打刻時刻どうしの差）" do
    attendance = build_attendance(clock_out_at: Time.zone.local(2026, 11, 24, 17, 45, 59))
    assert_equal 8 * 60 + 45, attendance.worked_minutes

    # 秒を切り捨てた時刻（画面に出る 22:00 と 02:00）どうしの差なので 4:00 になる（3:59 にはならない）
    overnight = build_attendance(work_date: Date.new(2026, 11, 23), clock_in_at: Time.zone.local(2026, 11, 23, 22, 0, 11),
                                 clock_out_at: Time.zone.local(2026, 11, 24, 2, 0, 8))
    assert_equal 4 * 60, overnight.worked_minutes
  end

  test "勤務中の実働時間は指定時刻までで数える" do
    attendance = build_attendance
    assert_equal 90, attendance.worked_minutes(as_of: Time.zone.local(2026, 11, 24, 10, 30))
  end

  test "日付をまたいだ勤務の判定" do
    assert_not build_attendance(clock_out_at: Time.zone.local(2026, 11, 24, 23, 59)).overnight?
    assert build_attendance(clock_out_at: Time.zone.local(2026, 11, 25, 2, 0)).overnight?
  end
end

class AttendanceBreakCalculationTest < ActiveSupport::TestCase
  def jst(*args)
    Time.zone.local(*args)
  end

  setup do
    @attendance = users(:employee).attendances.create!(work_date: Date.new(2026, 11, 24), clock_in_at: jst(2026, 11, 24, 9, 0))
  end

  test "実働時間＝退勤−出勤−休憩合計（複数回の休憩）" do
    @attendance.breaks.create!(started_at: jst(2026, 11, 24, 12, 0), ended_at: jst(2026, 11, 24, 12, 45))
    @attendance.breaks.create!(started_at: jst(2026, 11, 24, 15, 0), ended_at: jst(2026, 11, 24, 15, 15))
    @attendance.update!(clock_out_at: jst(2026, 11, 24, 18, 0))
    @attendance.reload

    assert_equal 9 * 60, @attendance.elapsed_minutes
    assert_equal 60, @attendance.break_minutes
    assert_equal 8 * 60, @attendance.worked_minutes
  end

  test "休憩中は休憩時間が増え、実働時間は止まる" do
    @attendance.breaks.create!(started_at: jst(2026, 11, 24, 12, 0))
    @attendance.reload

    assert @attendance.on_break?
    assert_equal 30, @attendance.break_minutes(as_of: jst(2026, 11, 24, 12, 30))
    assert_equal 3 * 60, @attendance.worked_minutes(as_of: jst(2026, 11, 24, 12, 30))
    assert_equal 3 * 60, @attendance.worked_minutes(as_of: jst(2026, 11, 24, 12, 59))
    assert_equal 0, @attendance.finished_break_minutes
  end

  test "日付をまたぐ休憩（23:30〜翌0:30）も出勤した日の勤務の休憩として数える" do
    attendance = users(:admin).attendances.create!(work_date: Date.new(2026, 11, 23), clock_in_at: jst(2026, 11, 23, 20, 0))
    attendance.breaks.create!(started_at: jst(2026, 11, 23, 23, 30), ended_at: jst(2026, 11, 24, 0, 30))
    attendance.update!(clock_out_at: jst(2026, 11, 24, 2, 0))
    attendance.reload

    assert_equal 60, attendance.break_minutes
    assert_equal 5 * 60, attendance.worked_minutes
  end

  test "休憩が無ければ休憩合計は 0" do
    assert_equal 0, @attendance.break_minutes(as_of: jst(2026, 11, 24, 10, 0))
    assert_not @attendance.on_break?
  end
end
