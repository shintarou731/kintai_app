require "test_helper"

# 予実比較（F12。ShiftCheck）：遅刻・早退・欠勤の判定と、その境界。時刻はすべて固定する
class ShiftCheckTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-25（水）15:00
  NOW = Time.zone.local(2026, 11, 25, 15, 0)
  PAST = Date.new(2026, 11, 24) # 火曜日

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
  end

  teardown { travel_back }

  def published_shift!(date: PAST, start_time: "9:00", end_time: "18:00", break_minutes: 60, user: @employee)
    shift = Shift.create!(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: break_minutes)
    shift.publish_draft!(now: NOW - 1.day)
    shift.reload
  end

  def attendance!(clock_in_at, clock_out_at = nil, date: PAST, user: @employee)
    Attendance.create!(user: user, work_date: date, clock_in_at: clock_in_at, clock_out_at: clock_out_at)
  end

  def approved_leave!(date, part: "full_day", type: "paid", user: @employee)
    leave = user.leave_requests.new(target_date: date, end_date: date, leave_type: type, day_part: part, reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  def check(shift, attendance, leaves: [], now: NOW)
    ShiftCheck.new(shift: shift, attendance: attendance, leaves: leaves, now: now)
  end

  def at(date, hour, minute, second = 0)
    Time.zone.local(date.year, date.month, date.day, hour, minute, second)
  end

  test "遅刻の境界：9:00 開始で 9:01:59 の出勤は遅刻にせず、9:02:00 は遅刻（2分）" do
    shift = published_shift!
    { [ 8, 50, 0 ] => 0, [ 9, 0, 0 ] => 0, [ 9, 0, 59 ] => 0, [ 9, 1, 0 ] => 0, [ 9, 1, 59 ] => 0, [ 9, 2, 0 ] => 2, [ 9, 15, 30 ] => 15 }
      .each do |(hour, minute, second), expected|
        attendance = Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, hour, minute, second), clock_out_at: at(PAST, 18, 0))
        result = check(shift, attendance)
        assert_equal expected, result.late_minutes, "#{hour}:#{minute}:#{second}"
        assert_equal expected.positive?, result.late?, "#{hour}:#{minute}:#{second}"
      end
  end

  test "早退の境界：18:00 終了で 17:59:00 の退勤は早退にせず、17:58:59 は早退（秒を切り捨てて 17:58＝2分）" do
    shift = published_shift!
    { [ 18, 30, 0 ] => 0, [ 18, 0, 0 ] => 0, [ 17, 59, 59 ] => 0, [ 17, 59, 0 ] => 0, [ 17, 58, 59 ] => 2, [ 17, 58, 0 ] => 2, [ 17, 0, 0 ] => 60 }
      .each do |(hour, minute, second), expected|
        attendance = Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, 9, 0), clock_out_at: at(PAST, hour, minute, second))
        result = check(shift, attendance)
        assert_equal expected, result.early_leave_minutes, "#{hour}:#{minute}:#{second}"
        assert_equal expected.positive?, result.early_leave?, "#{hour}:#{minute}:#{second}"
      end
  end

  test "遅刻と早退は同じ日に両方付く。予定どおりなら印は無い" do
    shift = published_shift!
    both = check(shift, attendance!(at(PAST, 9, 30), at(PAST, 17, 0)))
    assert_equal %i[late early_leave], both.marks
    assert_equal :done, both.status

    shift2 = published_shift!(date: PAST - 1)
    ok = check(shift2, attendance!(at(PAST - 1, 8, 55), at(PAST - 1, 18, 5), date: PAST - 1))
    assert_empty ok.marks
    assert_equal :done, ok.status
  end

  test "日付をまたぐシフト（22:00〜翌6:00）：終了は翌日の時刻で比べる" do
    shift = published_shift!(start_time: "22:00", end_time: "6:00")
    next_day = PAST + 1
    assert_not check(shift, attendance!(at(PAST, 22, 1, 59), at(next_day, 6, 0))).late?

    { at(PAST, 22, 2) => [ true, false ], at(PAST, 21, 50) => [ false, false ] }.each do |clock_in, (late, early)|
      attendance = Attendance.new(user: @employee, work_date: PAST, clock_in_at: clock_in, clock_out_at: at(next_day, 6, 0))
      result = check(shift, attendance)
      assert_equal [ late, early ], [ result.late?, result.early_leave? ], clock_in.to_s
    end
    # 翌 5:59 は早退にしない。翌 5:58 は早退。翌 7:00 の退勤も早退ではない
    { at(next_day, 5, 59) => false, at(next_day, 5, 58) => true, at(next_day, 7, 0) => false, at(PAST, 23, 30) => true }.each do |clock_out, early|
      attendance = Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, 22, 0), clock_out_at: clock_out)
      assert_equal early, check(shift, attendance).early_leave?, clock_out.to_s
    end
  end

  test "日付をまたぐシフトの欠勤は、翌日の終了時刻を過ぎてから決まる" do
    date = Date.new(2026, 11, 24)
    shift = published_shift!(date: date, start_time: "22:00", end_time: "6:00")
    assert_equal :not_clocked_in, check(shift, nil, now: at(date + 1, 3, 0)).status
    assert_not check(shift, nil, now: at(date + 1, 5, 59)).absent?
    assert check(shift, nil, now: at(date + 1, 6, 0)).absent?
  end

  test "欠勤：シフトがあるのに打刻も休暇も無い過去の日。全日の休暇の日は欠勤にしない" do
    shift = published_shift!
    absent = check(shift, nil)
    assert absent.absent?
    assert_equal [ :absent ], absent.marks
    assert_equal :absent, absent.status

    leave = approved_leave!(PAST)
    on_leave = check(shift, nil, leaves: [ leave ])
    assert_not on_leave.absent?
    assert_empty on_leave.marks
    assert_equal :on_leave, on_leave.status
  end

  test "全日の休暇（種類が「欠勤」の休暇も）の日は、打刻があっても遅刻・早退にしない" do
    shift = published_shift!
    leave = approved_leave!(PAST, type: "absence")
    result = check(shift, attendance!(at(PAST, 11, 0), at(PAST, 12, 0)), leaves: [ leave ])
    assert_empty result.marks
    assert result.covered_by_leave?
  end

  test "当日：開始前は「これから」、開始の1分後までは未出勤にしない、終了前は欠勤にしない、終了後は欠勤" do
    today = NOW.to_date
    shift = published_shift!(date: today, start_time: "14:00", end_time: "20:00")
    assert_equal :upcoming, check(shift, nil, now: at(today, 13, 59)).status
    assert_equal :upcoming, check(shift, nil, now: at(today, 14, 1, 59)).status
    assert_equal :not_clocked_in, check(shift, nil, now: at(today, 14, 2)).status
    assert_not check(shift, nil, now: at(today, 19, 59)).absent?
    assert_empty check(shift, nil, now: at(today, 19, 59)).marks
    assert check(shift, nil, now: at(today, 20, 0)).absent?
  end

  test "勤務中は早退を判定しない（遅刻は出勤した時点で決まる）" do
    today = NOW.to_date
    shift = published_shift!(date: today, start_time: "9:00", end_time: "18:00")
    result = check(shift, attendance!(at(today, 9, 10), date: today))
    assert_equal :working, result.status
    assert result.late?
    assert_not result.early_leave?
    assert result.early_leave_pending?
  end

  test "退勤漏れの日：遅刻は判定し、早退は判定できないので付けない" do
    shift = published_shift!
    result = check(shift, attendance!(at(PAST, 9, 5)))
    assert_equal :missing_clock_out, result.status
    assert_equal [ :late ], result.marks
    assert_not result.absent?
  end

  test "休憩は判定に使わない（休憩が長くても、開始・終了どおりなら印は無い）" do
    shift = published_shift!(break_minutes: 30)
    attendance = attendance!(at(PAST, 9, 0), at(PAST, 18, 0))
    attendance.breaks.create!(started_at: at(PAST, 12, 0), ended_at: at(PAST, 14, 0))
    assert_empty check(shift, attendance.reload).marks
  end

  test "午前半休：開始が 12:00 より前のシフトは、出勤の基準を 13:00 にする（13:01 は遅刻にせず、13:02 は遅刻）" do
    shift = published_shift!
    leave = approved_leave!(PAST, part: "morning")
    result = check(shift, Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, 13, 1, 59), clock_out_at: at(PAST, 18, 0)),
                   leaves: [ leave ])
    assert_equal at(PAST, 13, 0), result.expected_starts_at
    assert result.adjusted_for_half_day?
    assert_not result.late?
    late = check(shift, Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, 13, 2), clock_out_at: at(PAST, 18, 0)),
                 leaves: [ leave ])
    assert_equal 2, late.late_minutes
    # 退勤の基準は 18:00 のまま
    early = check(shift, Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, 13, 0), clock_out_at: at(PAST, 17, 0)),
                  leaves: [ leave ])
    assert early.early_leave?
  end

  test "午前半休：12:00 以降に始まるシフトは、シフトの開始のまま判定する" do
    shift = published_shift!(start_time: "12:00", end_time: "18:00")
    leave = approved_leave!(PAST, part: "morning")
    result = check(shift, Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, 12, 2), clock_out_at: at(PAST, 18, 0)),
                   leaves: [ leave ])
    assert_not result.adjusted_for_half_day?
    assert result.late?
  end

  test "午後半休：終了が 13:00 より後のシフトは、退勤の基準を 12:00 にする（12:00 は早退にせず、11:58 は早退）" do
    shift = published_shift!
    leave = approved_leave!(PAST, part: "afternoon")
    ok = check(shift, Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, 9, 0), clock_out_at: at(PAST, 12, 0)),
               leaves: [ leave ])
    assert_equal at(PAST, 12, 0), ok.expected_ends_at
    assert_not ok.early_leave?
    early = check(shift, Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, 9, 0), clock_out_at: at(PAST, 11, 58)),
                  leaves: [ leave ])
    assert early.early_leave?
    # 13:00 に終わるシフト（半休と重ならない）は、13:00 のまま
    shift13 = published_shift!(date: PAST - 1, end_time: "13:00", break_minutes: 0)
    leave13 = approved_leave!(PAST - 1, part: "afternoon")
    result = check(shift13, Attendance.new(user: @employee, work_date: PAST - 1, clock_in_at: at(PAST - 1, 9, 0), clock_out_at: at(PAST - 1, 12, 0)),
                   leaves: [ leave13 ])
    assert result.early_leave?
  end

  test "半休でシフトの時間がすべて埋まる日（午前半休の 9:00〜12:30）は、休暇の日と同じ扱い" do
    shift = published_shift!(end_time: "12:30", break_minutes: 0)
    leave = approved_leave!(PAST, part: "morning")
    result = check(shift, nil, leaves: [ leave ])
    assert result.covered_by_leave?
    assert_equal :on_leave, result.status
    assert_not result.absent?
  end

  test "半休の日でも、働く時間が残っているのに打刻が無ければ欠勤（終了の基準を過ぎてから）" do
    shift = published_shift!
    leave = approved_leave!(PAST, part: "afternoon")
    assert check(shift, nil, leaves: [ leave ]).absent?
  end

  test "一度も公開していないシフト（下書き）は「シフトなし」として扱い、印を付けない" do
    draft = Shift.create!(user: @employee, work_date: PAST, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    result = check(draft, nil)
    assert_not result.scheduled?
    assert_equal :no_shift, result.status
    assert_empty result.marks
  end

  test "公開後に変えてまだ公開していない内容は使わず、公開中の時刻で判定する" do
    shift = published_shift!
    shift.update!(start_time: "10:00")
    assert_equal "9:00〜18:00", shift.published_range_label
    result = check(shift, Attendance.new(user: @employee, work_date: PAST, clock_in_at: at(PAST, 9, 30), clock_out_at: at(PAST, 18, 0)))
    assert result.late?
    assert_equal 30, result.late_minutes
  end

  test "シフトの無い日の勤務には印を付けない" do
    result = check(nil, attendance!(at(PAST, 11, 0), at(PAST, 12, 0)))
    assert_equal :no_shift, result.status
    assert_empty result.marks
  end

  test "シフトの開始前に退勤した勤務は、シフトの終了を過ぎるまで早退にしない（スプリント12の指摘）" do
    today = NOW.to_date
    shift = published_shift!(date: today, start_time: "17:00", end_time: "22:00")
    attendance = attendance!(at(today, 0, 24, 10), at(today, 0, 24, 40), date: today)

    before = check(shift, attendance, now: at(today, 9, 30))
    assert_not before.early_leave?
    assert_equal 0, before.early_leave_minutes
    assert_equal :left_before_start, before.status
    assert before.early_leave_pending?
    assert_empty before.marks

    assert_not check(shift, attendance, now: at(today, 21, 59)).early_leave?, "終了の直前もまだ決めない"
    after = check(shift, attendance, now: at(today, 22, 0))
    assert after.early_leave?, "シフトの終了を過ぎたら、ふつうに早退として判定する"
    assert_equal :done, after.status
  end

  test "シフトの開始後に退勤した勤務は、これまでどおり退勤した時点で早退と判定する" do
    today = NOW.to_date
    shift = published_shift!(date: today, start_time: "9:00", end_time: "18:00")
    attendance = attendance!(at(today, 9, 0), at(today, 14, 0), date: today)
    result = check(shift, attendance, now: at(today, 14, 30))
    assert result.early_leave?
    assert_equal 240, result.early_leave_minutes
    assert_equal :done, result.status
  end
end
