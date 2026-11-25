require "test_helper"

# TimeClock の休憩（休憩開始・休憩終了）と、休憩に関わる退勤の制限
class TimeClockBreakTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:employee)
  end

  def jst(*args)
    Time.zone.local(*args)
  end

  def at(*args, &block)
    travel_to(jst(*args), &block)
  end

  def clock
    TimeClock.new(@user)
  end

  def error_message(&block)
    assert_raises(TimeClock::Error, &block).message
  end

  test "勤務中 → 休憩開始で休憩中 → 休憩終了で勤務中に戻る" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }

    at 2026, 11, 24, 12, 0, 20 do
      assert clock.can_start_break?
      assert_not clock.can_end_break?
      attendance_break = clock.start_break!
      assert_equal jst(2026, 11, 24, 12, 0, 20), attendance_break.started_at

      current = clock
      assert_equal :on_break, current.state
      assert current.can_end_break?
      assert_not current.can_start_break?
      assert_not current.can_clock_out?, "休憩中は退勤できない"
      assert_not current.can_clock_in?
    end

    at 2026, 11, 24, 13, 0, 5 do
      attendance_break = clock.end_break!
      assert_equal jst(2026, 11, 24, 13, 0, 5), attendance_break.ended_at
      assert_equal 60, attendance_break.duration_minutes
      assert_equal :working, clock.state
      assert clock.can_clock_out?
    end
  end

  test "1日に複数回休憩でき、実働時間は退勤−出勤−休憩合計" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }
    at(2026, 11, 24, 12, 0) { clock.start_break! }
    at(2026, 11, 24, 12, 45) { clock.end_break! }
    at(2026, 11, 24, 15, 0) { clock.start_break! }
    at(2026, 11, 24, 15, 15) { clock.end_break! }

    attendance = at(2026, 11, 24, 18, 0) { clock.clock_out! }
    assert_equal 2, attendance.breaks.size
    assert_equal 60, attendance.break_minutes
    assert_equal 8 * 60, attendance.worked_minutes
  end

  test "休憩中は退勤できない" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }
    at(2026, 11, 24, 12, 0) { clock.start_break! }

    at 2026, 11, 24, 12, 30 do
      assert_equal "休憩中のため、退勤できません。先に「休憩終了」を押してください。", error_message { clock.clock_out! }
    end
    assert_nil @user.attendances.sole.clock_out_at
  end

  test "画面表示時点では勤務中でも、その後に休憩が始まっていれば退勤しない（休憩開始と退勤の競合）" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }
    stale = at(2026, 11, 24, 12, 0) { clock.tap(&:current_attendance) }
    at(2026, 11, 24, 12, 0) { clock.start_break! }

    at 2026, 11, 24, 12, 0, 1 do
      assert_match "休憩中のため、退勤できません", error_message { stale.clock_out! }
    end
    assert_nil @user.attendances.sole.clock_out_at
  end

  test "画面表示時点では勤務中でも、その後に退勤していれば休憩を始めない（退勤と休憩開始の競合）" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }
    stale = at(2026, 11, 24, 18, 0) { clock.tap(&:current_attendance) }
    at(2026, 11, 24, 18, 0) { clock.clock_out! }

    at 2026, 11, 24, 18, 0, 1 do
      assert_equal "本日の勤務は退勤済みのため、休憩を開始できません。", error_message { stale.start_break! }
    end
    assert_equal 0, AttendanceBreak.count
  end

  test "未出勤・退勤済みでは休憩を開始・終了できない" do
    at 2026, 11, 24, 8, 0 do
      assert_not clock.can_start_break?
      assert_not clock.can_end_break?
      assert_equal "出勤していないため、休憩を開始できません。先に出勤を打刻してください。", error_message { clock.start_break! }
      assert_equal "出勤していないため、休憩を終了できません。", error_message { clock.end_break! }
    end

    at(2026, 11, 24, 9, 0) { clock.clock_in! }
    at(2026, 11, 24, 18, 0) { clock.clock_out! }

    at 2026, 11, 24, 18, 30 do
      assert_equal :finished, clock.state
      assert_not clock.can_start_break?
      assert_not clock.can_end_break?
      assert_equal "本日の勤務は退勤済みのため、休憩を開始できません。", error_message { clock.start_break! }
      assert_equal "本日の勤務は退勤済みのため、休憩を終了できません。", error_message { clock.end_break! }
    end
    assert_equal 0, AttendanceBreak.count
  end

  test "休憩開始を2回押しても休憩は1件" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }

    at 2026, 11, 24, 12, 0 do
      clock.start_break!
      assert_equal "すでに休憩中です（12:00 から）。休憩を終えたら「休憩終了」を押してください。", error_message { clock.start_break! }
    end
    assert_equal 1, AttendanceBreak.count
  end

  test "同時に届いた2回目の休憩開始（画面表示時点では勤務中）も1件だけ" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }

    at 2026, 11, 24, 12, 0 do
      first = clock
      second = clock
      assert first.can_start_break?
      assert second.can_start_break?

      first.start_break!
      assert_match "すでに休憩中です", error_message { second.start_break! }
    end
    assert_equal 1, AttendanceBreak.count
  end

  test "休憩終了を2回押しても最初の終了時刻のまま" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }
    at(2026, 11, 24, 12, 0) { clock.start_break! }
    stale = at(2026, 11, 24, 13, 0) { clock.tap(&:current_attendance) }
    at(2026, 11, 24, 13, 0) { clock.end_break! }

    at 2026, 11, 24, 13, 0, 2 do
      assert_equal "すでに休憩を終了しています（13:00 に終了）。", error_message { stale.end_break! }
      assert_equal "すでに休憩を終了しています（13:00 に終了）。", error_message { clock.end_break! }
    end
    assert_equal jst(2026, 11, 24, 13, 0), AttendanceBreak.sole.ended_at
  end

  test "勤務中で休憩が1回も無いときに休憩終了を押すと、休憩中ではないと案内する" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }
    at 2026, 11, 24, 10, 0 do
      assert_equal "休憩中ではないため、休憩を終了できません。", error_message { clock.end_break! }
    end
  end

  test "日付をまたぐ休憩（23:30〜翌0:30）：翌日も休憩中のまま、出勤した日の勤務の休憩として終了できる" do
    at(2026, 11, 23, 20, 0) { clock.clock_in! }
    at(2026, 11, 23, 23, 30) { clock.start_break! }

    at 2026, 11, 24, 0, 15 do
      current = clock
      assert_equal :on_break, current.state
      assert_equal Date.new(2026, 11, 23), current.attendance.work_date
      assert_equal 45, current.attendance.break_minutes(as_of: current.now)
      assert_not current.can_clock_in?, "日付が変わっても前日の勤務の続き"
    end

    at 2026, 11, 24, 0, 30 do
      attendance_break = clock.end_break!
      assert_equal 60, attendance_break.duration_minutes
      assert_equal Date.new(2026, 11, 23), attendance_break.attendance.work_date
    end

    attendance = at(2026, 11, 24, 2, 0) { clock.clock_out! }
    assert_equal Date.new(2026, 11, 23), attendance.work_date
    assert_equal 60, attendance.break_minutes
    assert_equal 5 * 60, attendance.worked_minutes # 20:00〜02:00 の 6時間 − 休憩 1時間
  end

  test "休憩中に出勤を押しても出勤済みと案内する" do
    at(2026, 11, 24, 9, 0) { clock.clock_in! }
    at(2026, 11, 24, 12, 0) { clock.start_break! }
    at 2026, 11, 24, 12, 10 do
      assert_match "すでに出勤しています（09:00 に出勤）", error_message { clock.clock_in! }
    end
  end

  # スプリント3評価の指摘2：前日の勤務の退勤時刻を理由にしたメッセージを出さない
  test "日付をまたいだ前日の勤務を退勤した後、その日の夜に退勤を送ると「出勤していない」と案内する" do
    at(2026, 11, 23, 22, 0) { clock.clock_in! }
    at(2026, 11, 24, 2, 0) { clock.clock_out! }

    at 2026, 11, 24, 19, 1 do
      assert_equal "出勤していないため、退勤できません。先に出勤を打刻してください。", error_message { clock.clock_out! }
    end
  end

  test "ほかの従業員の勤怠IDを指定しても、その退勤時刻はメッセージに使わない" do
    other = at(2026, 11, 24, 9, 0) { TimeClock.new(users(:admin)).clock_in! }
    at(2026, 11, 24, 10, 0) { TimeClock.new(users(:admin)).clock_out! }

    at 2026, 11, 24, 11, 0 do
      assert_match "出勤していないため", error_message { clock.clock_out!(attendance_id: other.id) }
    end
  end
end
