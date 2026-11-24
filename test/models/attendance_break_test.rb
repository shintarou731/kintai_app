require "test_helper"

class AttendanceBreakTest < ActiveSupport::TestCase
  setup do
    @attendance = users(:employee).attendances.create!(work_date: Date.new(2026, 11, 24), clock_in_at: jst(2026, 11, 24, 9, 0))
  end

  def jst(*args)
    Time.zone.local(*args)
  end

  test "休憩開始時刻は必須" do
    attendance_break = @attendance.breaks.build
    assert_not attendance_break.valid?
    assert attendance_break.errors[:started_at].any?
  end

  test "休憩終了は休憩開始より前にできない" do
    attendance_break = @attendance.breaks.build(started_at: jst(2026, 11, 24, 12, 0), ended_at: jst(2026, 11, 24, 11, 59))
    assert_not attendance_break.valid?
    assert_includes attendance_break.errors.full_messages, "休憩終了時刻は休憩開始時刻より後にしてください"
  end

  test "休憩開始は出勤より前にできない" do
    attendance_break = @attendance.breaks.build(started_at: jst(2026, 11, 24, 8, 59))
    assert_not attendance_break.valid?
    assert_includes attendance_break.errors.full_messages, "休憩開始時刻は出勤時刻より後にしてください"
  end

  test "休憩時間は分単位の打刻時刻どうしの差。休憩中は指定時刻まで" do
    finished = @attendance.breaks.build(started_at: jst(2026, 11, 24, 12, 0, 50), ended_at: jst(2026, 11, 24, 13, 0, 10))
    assert_equal 60, finished.duration_minutes

    ongoing = @attendance.breaks.build(started_at: jst(2026, 11, 24, 15, 0, 30))
    assert ongoing.open?
    assert_equal 14, ongoing.duration_minutes(as_of: jst(2026, 11, 24, 15, 14, 59))
  end

  test "データベースの一意制約で、1つの勤怠に休憩中の休憩は1件まで" do
    @attendance.breaks.create!(started_at: jst(2026, 11, 24, 12, 0))
    duplicate = @attendance.breaks.build(started_at: jst(2026, 11, 24, 12, 0, 1))
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save(validate: false) }

    # 終わった休憩は何件あってもよい
    @attendance.breaks.first.update!(ended_at: jst(2026, 11, 24, 12, 30))
    @attendance.breaks.create!(started_at: jst(2026, 11, 24, 15, 0), ended_at: jst(2026, 11, 24, 15, 10))
    @attendance.breaks.create!(started_at: jst(2026, 11, 24, 16, 0))
    assert_equal 3, @attendance.breaks.count
  end
end
