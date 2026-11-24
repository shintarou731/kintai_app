require "test_helper"

# 勤怠履歴（F5）で使う、1日の残業時間・深夜時間・退勤漏れの判定
class AttendanceNightAndOvertimeTest < ActiveSupport::TestCase
  def t(day, hour, min = 0, sec = 0)
    Time.zone.local(2026, 11, day, hour, min, sec)
  end

  def attendance(clock_in:, clock_out:, breaks: [])
    record = users(:employee).attendances.create!(work_date: clock_in.to_date, clock_in_at: clock_in, clock_out_at: clock_out)
    breaks.each { |from, to| record.breaks.create!(started_at: from, ended_at: to) }
    record.reload
  end

  # --- 残業時間 ---

  test "残業時間は実働のうち所定労働時間を超えた部分。所定ちょうどなら 0:00" do
    exact = attendance(clock_in: t(2, 9), clock_out: t(2, 18), breaks: [ [ t(2, 12), t(2, 13) ] ]) # 実働 8:00
    assert_equal 480, exact.worked_minutes
    assert_equal 0, exact.overtime_minutes(scheduled_minutes: 480)

    one_minute = attendance(clock_in: t(3, 9), clock_out: t(3, 18, 1), breaks: [ [ t(3, 12), t(3, 13) ] ]) # 実働 8:01
    assert_equal 1, one_minute.overtime_minutes(scheduled_minutes: 480)

    short = attendance(clock_in: t(4, 9), clock_out: t(4, 13)) # 実働 4:00
    assert_equal 0, short.overtime_minutes(scheduled_minutes: 480)
  end

  test "残業時間は所定労働時間の設定に従う（所定 7:00 なら実働 8:00 の残業は 1:00）" do
    record = attendance(clock_in: t(2, 9), clock_out: t(2, 18), breaks: [ [ t(2, 12), t(2, 13) ] ])
    assert_equal 60, record.overtime_minutes(scheduled_minutes: 7 * 60)
  end

  # --- 深夜時間 ---

  test "22:00 ちょうどに退勤した勤務の深夜時間は 0:00、22:01 なら 0:01" do
    assert_equal 0, attendance(clock_in: t(2, 13), clock_out: t(2, 22)).night_minutes
    assert_equal 1, attendance(clock_in: t(3, 13), clock_out: t(3, 22, 1)).night_minutes
  end

  test "22:00 ちょうどに出勤した勤務は出勤直後から深夜時間" do
    assert_equal 60, attendance(clock_in: t(2, 22), clock_out: t(2, 23)).night_minutes
  end

  test "5:00 ちょうどに出勤した勤務の深夜時間は 0:00、4:59 出勤なら 0:01" do
    assert_equal 0, attendance(clock_in: t(2, 5), clock_out: t(2, 14)).night_minutes
    assert_equal 1, attendance(clock_in: t(3, 4, 59), clock_out: t(3, 14)).night_minutes
  end

  test "日付をまたぐ勤務は 22:00〜翌5:00 の部分だけが深夜（20:00〜翌6:00 なら 7:00）" do
    record = attendance(clock_in: t(2, 20), clock_out: t(3, 6))
    assert_equal 600, record.worked_minutes
    assert_equal 420, record.night_minutes
  end

  test "深夜帯にかかる休憩はその分を差し引く（23:30〜翌0:30 の休憩）" do
    record = attendance(clock_in: t(2, 20), clock_out: t(3, 2), breaks: [ [ t(2, 23, 30), t(3, 0, 30) ] ])
    assert_equal 300, record.worked_minutes # 6:00 − 休憩 1:00
    assert_equal 180, record.night_minutes  # 22:00〜2:00 の 4:00 − 休憩 1:00
  end

  test "深夜帯の境目をまたぐ休憩は、深夜帯に入っている部分だけを差し引く" do
    # 21:30〜22:30 の休憩：深夜帯にかかるのは 22:00〜22:30 の 30 分
    evening = attendance(clock_in: t(2, 17), clock_out: t(2, 23), breaks: [ [ t(2, 21, 30), t(2, 22, 30) ] ])
    assert_equal 30, evening.night_minutes # 22:00〜23:00 の 60 分 − 30 分

    # 4:30〜5:30 の休憩：深夜帯にかかるのは 4:30〜5:00 の 30 分
    morning = attendance(clock_in: t(3, 4), clock_out: t(3, 9), breaks: [ [ t(3, 4, 30), t(3, 5, 30) ] ])
    assert_equal 30, morning.night_minutes # 4:00〜5:00 の 60 分 − 30 分
  end

  test "深夜帯の外の休憩は深夜時間に影響しない" do
    record = attendance(clock_in: t(2, 18), clock_out: t(2, 23), breaks: [ [ t(2, 19), t(2, 20) ] ])
    assert_equal 60, record.night_minutes
  end

  test "深夜時間も秒を切り捨てた時刻で数える" do
    record = attendance(clock_in: t(2, 21, 59, 59), clock_out: t(2, 22, 30, 59))
    assert_equal 30, record.night_minutes
  end

  test "早朝から翌朝までの長い勤務は2つの深夜帯を数える（4:00〜翌5:30 → 1:00 ＋ 7:00）" do
    record = attendance(clock_in: t(2, 4), clock_out: t(3, 5, 30))
    assert_equal 480, record.night_minutes
  end

  test "勤務中の深夜時間は指定時刻までで数える" do
    record = users(:employee).attendances.create!(work_date: Date.new(2026, 11, 2), clock_in_at: t(2, 21))
    assert_equal 30, record.night_minutes(as_of: t(2, 22, 30))
    assert_equal 0, record.night_minutes(as_of: t(2, 21, 30))
  end

  # --- 退勤漏れ ---

  test "退勤の打刻が無いまま勤務日が過ぎた勤務は退勤漏れ（出勤から24時間以内かどうかに関係しない）" do
    record = users(:employee).attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10))
    assert_not record.missing_clock_out?(as_of: t(10, 23, 59, 59)) # 勤務日の当日
    assert record.missing_clock_out?(as_of: t(11, 0, 0))            # 日付が過ぎた（出勤から14時間）
    assert record.missing_clock_out?(as_of: t(11, 9, 59))           # 出勤から24時間以内
    assert record.missing_clock_out?(as_of: t(11, 10, 0, 1))        # 出勤から24時間超

    finished = attendance(clock_in: t(4, 9), clock_out: t(4, 18))
    assert_not finished.missing_clock_out?(as_of: t(20, 0))
  end

  test "ホームから退勤できるのは出勤から24時間まで" do
    record = users(:employee).attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10))
    assert_equal t(11, 10), record.clock_out_deadline
    assert record.clock_out_open?(as_of: t(10, 23))
    assert record.clock_out_open?(as_of: t(11, 9, 59))
    assert record.clock_out_open?(as_of: t(11, 10, 0))
    assert_not record.clock_out_open?(as_of: t(11, 10, 0, 1))

    finished = attendance(clock_in: t(4, 9), clock_out: t(4, 18))
    assert_not finished.clock_out_open?(as_of: t(4, 19))
  end

  test "ホームから退勤できる期限は TimeClock の現在の勤務の判定と一致する" do
    user = users(:employee)
    record = user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10))
    [ t(11, 9, 59), t(11, 10, 0), t(11, 10, 0, 1) ].each do |now|
      assert_equal record.clock_out_open?(as_of: now), TimeClock.new(user, now: now).current_attendance == record, now.to_s
    end
  end

  test "退勤できる期限は出勤時刻の秒を切り捨てて数え、表示（分まで）と判定が一致する" do
    user = users(:employee)
    record = user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10, 0, 8))
    assert_equal t(11, 10), record.clock_out_deadline # 表示は「11/11(水) 10:00」
    assert record.clock_out_open?(as_of: t(11, 10, 0, 0))
    assert_not record.clock_out_open?(as_of: t(11, 10, 0, 1))
    assert_not record.clock_out_open?(as_of: t(11, 10, 0, 8)) # 以前は秒まで数えていたため、ここまで退勤できた

    [ t(11, 9, 59, 59), t(11, 10, 0, 0), t(11, 10, 0, 1), t(11, 10, 0, 8), t(11, 10, 0, 9) ].each do |now|
      time_clock = TimeClock.new(user, now: now)
      assert_equal record.clock_out_open?(as_of: now), time_clock.current_attendance == record, now.to_s
      assert_equal !record.clock_out_open?(as_of: now), time_clock.missing_clock_outs.include?(record), now.to_s
    end
  end
end
