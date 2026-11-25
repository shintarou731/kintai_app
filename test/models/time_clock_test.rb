require "test_helper"

class TimeClockTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:employee)
  end

  def jst(*args)
    Time.zone.local(*args)
  end

  test "タイムゾーンは日本時間" do
    assert_equal "Asia/Tokyo", Time.zone.tzinfo.name
  end

  test "未出勤 → 出勤 → 勤務中 → 退勤 → 退勤済み" do
    travel_to jst(2026, 11, 24, 9, 2, 30) do
      clock = TimeClock.new(@user)
      assert_equal :not_started, clock.state
      assert clock.can_clock_in?
      assert_not clock.can_clock_out?

      attendance = clock.clock_in!
      assert_equal Date.new(2026, 11, 24), attendance.work_date
      assert_equal jst(2026, 11, 24, 9, 2, 30), attendance.clock_in_at

      clock = TimeClock.new(@user)
      assert_equal :working, clock.state
      assert_not clock.can_clock_in?
      assert clock.can_clock_out?
    end

    travel_to jst(2026, 11, 24, 18, 5) do
      attendance = TimeClock.new(@user).clock_out!
      assert_equal jst(2026, 11, 24, 18, 5), attendance.clock_out_at
      assert_equal 9 * 60 + 3, attendance.worked_minutes # 分単位の打刻時刻 09:02 → 18:05 で数える

      clock = TimeClock.new(@user)
      assert_equal :finished, clock.state
      assert_not clock.can_clock_in?
      assert_not clock.can_clock_out?
      assert_equal attendance, clock.attendance
    end
  end

  test "退勤済みの日にもう一度出勤できない" do
    travel_to(jst(2026, 11, 24, 9, 0)) { TimeClock.new(@user).clock_in! }
    travel_to(jst(2026, 11, 24, 12, 0)) { TimeClock.new(@user).clock_out! }

    travel_to jst(2026, 11, 24, 13, 0) do
      error = assert_raises(TimeClock::Error) { TimeClock.new(@user).clock_in! }
      assert_match "本日はすでに退勤済み", error.message
    end
    assert_equal 1, @user.attendances.count
  end

  test "出勤を2回押しても1件しか記録されない" do
    travel_to jst(2026, 11, 24, 9, 0) do
      TimeClock.new(@user).clock_in!
      error = assert_raises(TimeClock::Error) { TimeClock.new(@user).clock_in! }
      assert_match "すでに出勤しています（09:00 に出勤）", error.message
    end
    assert_equal 1, @user.attendances.count
  end

  test "同時に届いた2回目の出勤（画面表示時点では未出勤）も1件しか記録されない" do
    travel_to jst(2026, 11, 24, 9, 0) do
      first = TimeClock.new(@user)
      second = TimeClock.new(@user)
      assert first.can_clock_in?
      assert second.can_clock_in? # どちらも「未出勤」と判断した後に…

      first.clock_in!
      error = assert_raises(TimeClock::Error) { second.clock_in! }
      assert_match "すでに出勤しています", error.message
    end
    assert_equal 1, @user.attendances.count
  end

  test "データベースの一意制約でも同じ日の2件目は保存できない" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 24), clock_in_at: jst(2026, 11, 24, 9, 0))
    duplicate = @user.attendances.build(work_date: Date.new(2026, 11, 24), clock_in_at: jst(2026, 11, 24, 9, 1))
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save(validate: false) }
  end

  test "退勤を2回押しても最初の退勤時刻のまま" do
    travel_to(jst(2026, 11, 24, 9, 0)) { TimeClock.new(@user).clock_in! }
    stale = travel_to(jst(2026, 11, 24, 18, 0)) { TimeClock.new(@user).tap(&:current_attendance) }
    travel_to(jst(2026, 11, 24, 18, 0)) { TimeClock.new(@user).clock_out! }

    travel_to jst(2026, 11, 24, 18, 0, 1) do
      # 画面表示時点（勤務中）の情報のまま2回目が届いても上書きしない
      error = assert_raises(TimeClock::Error) { stale.clock_out! }
      assert_match "すでに退勤しています（18:00 に退勤）", error.message
    end
    assert_equal jst(2026, 11, 24, 18, 0), @user.attendances.sole.clock_out_at
  end

  test "出勤していなければ退勤できない" do
    travel_to jst(2026, 11, 24, 9, 0) do
      error = assert_raises(TimeClock::Error) { TimeClock.new(@user).clock_out! }
      assert_match "出勤していないため", error.message
    end
    assert_equal 0, @user.attendances.count
  end

  test "22:00 出勤 → 翌 2:00 退勤は出勤した日の勤務になる" do
    travel_to(jst(2026, 11, 23, 22, 0)) { TimeClock.new(@user).clock_in! }

    travel_to jst(2026, 11, 24, 1, 30) do
      clock = TimeClock.new(@user)
      assert_equal :working, clock.state, "翌日になっても勤務中のまま"
      assert clock.can_clock_out?
      assert_not clock.can_clock_in?
      assert clock.attendance.overnight?
      assert_match "すでに出勤しています", assert_raises(TimeClock::Error) { clock.clock_in! }.message
    end

    travel_to jst(2026, 11, 24, 2, 0) do
      attendance = TimeClock.new(@user).clock_out!
      assert_equal Date.new(2026, 11, 23), attendance.work_date
      assert_equal jst(2026, 11, 24, 2, 0), attendance.clock_out_at
      assert_equal 4 * 60, attendance.worked_minutes

      # 退勤後、翌日（11/24）分はまだ未出勤。前日の勤務は参考として出す
      clock = TimeClock.new(@user)
      assert_equal :not_started, clock.state
      assert_equal attendance, clock.previous_attendance
      # 画面に出ていた勤務（退勤済み）を指定した再送信なら「すでに退勤」、指定が無ければ今日は未出勤なので「出勤していない」
      assert_match "すでに退勤しています（02:00 に退勤）", assert_raises(TimeClock::Error) { clock.clock_out!(attendance_id: attendance.id) }.message
      assert_match "出勤していないため", assert_raises(TimeClock::Error) { clock.clock_out! }.message
    end

    travel_to jst(2026, 11, 24, 9, 0) do
      attendance = TimeClock.new(@user).clock_in!
      assert_equal Date.new(2026, 11, 24), attendance.work_date
    end
    assert_equal 2, @user.attendances.count
  end

  test "0時ちょうどをまたぐ境界：23:59:59 の出勤はその日の勤務" do
    travel_to(jst(2026, 11, 30, 23, 59, 59)) { assert_equal Date.new(2026, 11, 30), TimeClock.new(@user).clock_in!.work_date }
    travel_to(jst(2026, 12, 1, 0, 0, 1)) { assert_equal Date.new(2026, 11, 30), TimeClock.new(@user).clock_out!.work_date }
  end

  test "UTC では前日でも、日本時間の日付を勤務日にする" do
    # 2026-11-24 08:00 JST = 2026-11-23 23:00 UTC
    travel_to Time.utc(2026, 11, 23, 23, 0) do
      assert_equal Date.new(2026, 11, 24), TimeClock.new(@user).clock_in!.work_date
    end
  end

  test "出勤から24時間を過ぎても退勤が無い勤務は退勤漏れとして扱い、その日の出勤を妨げない" do
    travel_to(jst(2026, 11, 23, 9, 0)) { TimeClock.new(@user).clock_in! }

    travel_to jst(2026, 11, 24, 9, 30) do
      clock = TimeClock.new(@user)
      assert_equal :not_started, clock.state
      assert_equal [ Date.new(2026, 11, 23) ], clock.missing_clock_outs.map(&:work_date)
      assert_raises(TimeClock::Error) { clock.clock_out! }
      assert_equal Date.new(2026, 11, 24), TimeClock.new(@user).clock_in!.work_date
    end
  end

  test "ほかの従業員の打刻とは独立している" do
    travel_to jst(2026, 11, 24, 9, 0) do
      TimeClock.new(users(:admin)).clock_in!
      assert_equal :not_started, TimeClock.new(@user).state
    end
  end
end
