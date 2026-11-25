require "test_helper"

# 休憩開始・休憩終了の打刻（BreakStartsController / BreakEndsController）と、休憩に関わるホーム画面の表示
class BreaksControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:employee)
  end

  def at(*args, &block)
    travel_to(Time.zone.local(*args), &block)
  end

  def clock_in_at(*args)
    at(*args) do
      sign_in_as @user
      post clock_in_path
    end
  end

  test "未ログインでは休憩を打刻できない" do
    post break_start_path
    assert_redirected_to login_path
    post break_end_path
    assert_redirected_to login_path
  end

  test "勤務中のホーム画面では休憩開始・退勤が押せ、休憩終了は押せない" do
    clock_in_at(2026, 11, 24, 9, 0)
    at 2026, 11, 24, 10, 0 do
      get root_path
      assert_select "[data-testid='break-start-button']:not([disabled])", "休憩開始"
      assert_select "[data-testid='break-end-button'][disabled]", "休憩終了"
      assert_select "[data-testid='clock-out-button']:not([disabled])"
      assert_select "[data-testid='break-time']", /0:00/
      assert_select "[data-testid='break-list']", count: 0
    end
  end

  test "休憩開始で休憩中になり、休憩終了だけが押せる（退勤は押せない）" do
    clock_in_at(2026, 11, 24, 9, 0)

    at 2026, 11, 24, 12, 0, 40 do
      assert_difference("AttendanceBreak.count", 1) { post break_start_path }
      assert_redirected_to root_path
      follow_redirect!
      assert_select ".flash--notice", "休憩を開始しました（12:00）"
      assert_select "[data-testid='time-clock-status'].status--break", "休憩中"
      assert_select "[data-testid='break-end-button']:not([disabled])", "休憩終了"
      assert_select "[data-testid='break-start-button'][disabled]"
      assert_select "[data-testid='clock-out-button'][disabled]"
      assert_select "[data-testid='clock-in-button'][disabled]"
      assert_select "[data-testid='punch-hint']", /休憩中は退勤できません/
    end

    at 2026, 11, 24, 12, 20 do
      get root_path
      # 休憩中は休憩合計が進み、実働時間は止まる（実働には時計の更新対象を付けない）
      assert_select "[data-testid='break-time'] [data-clock-target='duration']", "0:20"
      assert_select "[data-testid='worked-time']", /3:00/
      assert_select "[data-testid='worked-time'] [data-clock-target='duration']", count: 0
      assert_select "[data-testid='break-list'] li", 1
      assert_select "[data-testid='break-list'] li.breaks__item--open", /12:00〜.*休憩中/m
    end
  end

  test "休憩中に退勤を送っても退勤しない" do
    clock_in_at(2026, 11, 24, 9, 0)
    at(2026, 11, 24, 12, 0) { post break_start_path }

    at 2026, 11, 24, 12, 30 do
      post clock_out_path
      follow_redirect!
      assert_select ".flash--alert", "休憩中のため、退勤できません。先に「休憩終了」を押してください。"
      assert_select "[data-testid='time-clock-status']", "休憩中"
    end
    assert_nil @user.attendances.sole.clock_out_at
  end

  test "休憩終了で勤務中に戻り、休憩時間と合計が表示される" do
    clock_in_at(2026, 11, 24, 9, 0)
    at(2026, 11, 24, 12, 0) { post break_start_path }

    at 2026, 11, 24, 12, 45, 30 do
      post break_end_path
      follow_redirect!
      assert_select ".flash--notice", "休憩を終了しました（12:45）。今回の休憩は 0:45、休憩の合計は 0:45 です。"
      assert_select "[data-testid='time-clock-status']", "勤務中"
      assert_select "[data-testid='clock-out-button']:not([disabled])"
      assert_select "[data-testid='break-start-button']:not([disabled])"
      assert_select "[data-testid='break-time']", /0:45.*1回/m
      # 実働 = 3:45 − 0:45 = 3:00。勤務中は時計が進める
      assert_select "[data-testid='worked-time'] [data-clock-target='duration'][data-base-minutes='-45']", "3:00"
    end
  end

  test "複数回の休憩の合計がホーム画面に出て、退勤時の実働から差し引かれる" do
    clock_in_at(2026, 11, 24, 9, 0)
    at(2026, 11, 24, 12, 0) { post break_start_path }
    at(2026, 11, 24, 12, 45) { post break_end_path }
    at(2026, 11, 24, 15, 0) { post break_start_path }

    at 2026, 11, 24, 15, 15 do
      post break_end_path
      follow_redirect!
      assert_select ".flash--notice", "休憩を終了しました（15:15）。今回の休憩は 0:15、休憩の合計は 1:00 です。"
    end

    at 2026, 11, 24, 18, 0 do
      post clock_out_path, params: { attendance_id: @user.attendances.sole.id }
      follow_redirect!
      assert_select ".flash--notice", "退勤しました（18:00）。本日の実働時間は 8:00 です（休憩 1:00）。"
      assert_select "[data-testid='worked-time']", "8:00"
      assert_select "[data-testid='break-time']", /1:00.*2回/m
      assert_select "[data-testid='break-list'] li", 2
      assert_select "[data-testid='break-list'] li:nth-child(1)", /1回目.*12:00〜12:45.*0:45/m
      assert_select "[data-testid='break-list'] li:nth-child(2)", /2回目.*15:00〜15:15.*0:15/m
      assert_select "[data-testid='break-start-button'][disabled]"
      assert_select "[data-testid='break-end-button'][disabled]"
    end
  end

  test "未出勤では休憩ボタンが押せず、送ってもエラーで記録されない" do
    at 2026, 11, 24, 8, 0 do
      sign_in_as @user
      get root_path
      assert_select "[data-testid='break-start-button'][disabled]"
      assert_select "[data-testid='break-end-button'][disabled]"

      post break_start_path
      follow_redirect!
      assert_select ".flash--alert", "出勤していないため、休憩を開始できません。先に出勤を打刻してください。"
      post break_end_path
      follow_redirect!
      assert_select ".flash--alert", "出勤していないため、休憩を終了できません。"
    end
    assert_equal 0, AttendanceBreak.count
  end

  test "退勤済みでは休憩ボタンが押せず、送ってもエラーで記録されない" do
    clock_in_at(2026, 11, 24, 9, 0)
    at(2026, 11, 24, 18, 0) { post clock_out_path }

    at 2026, 11, 24, 18, 10 do
      get root_path
      assert_select "[data-testid='break-start-button'][disabled]"
      assert_select "[data-testid='break-end-button'][disabled]"

      post break_start_path
      follow_redirect!
      assert_select ".flash--alert", "本日の勤務は退勤済みのため、休憩を開始できません。"
    end
    assert_equal 0, AttendanceBreak.count
  end

  test "休憩開始・休憩終了を2回送っても（二重クリック・戻って再送信）1件で、最初の時刻のまま" do
    clock_in_at(2026, 11, 24, 9, 0)

    at 2026, 11, 24, 12, 0 do
      post break_start_path
      assert_no_difference("AttendanceBreak.count") { post break_start_path }
      follow_redirect!
      assert_select ".flash--alert", "すでに休憩中です（12:00 から）。休憩を終えたら「休憩終了」を押してください。"
    end

    at(2026, 11, 24, 13, 0) { post break_end_path }
    at 2026, 11, 24, 13, 0, 1 do
      post break_end_path
      follow_redirect!
      assert_select ".flash--alert", "すでに休憩を終了しています（13:00 に終了）。"
    end
    assert_equal Time.zone.local(2026, 11, 24, 13, 0), AttendanceBreak.sole.ended_at
  end

  test "日付をまたぐ休憩（23:30〜翌0:30）：翌日のホーム画面で休憩終了でき、出勤した日の勤務に記録される" do
    clock_in_at(2026, 11, 23, 20, 0)
    at(2026, 11, 23, 23, 30) { post break_start_path }

    at 2026, 11, 24, 0, 10 do
      get root_path
      assert_select ".punch__date", "2026年11月24日(火)"
      assert_select "[data-testid='time-clock-status']", "休憩中"
      assert_select "[data-testid='overnight-note']", /11\/23\(月\) 20:00 に出勤した勤務の続きです/
      assert_select "[data-testid='today-attendance'] h2", /11\/23\(月\) の勤務/
      assert_select "[data-testid='break-time'] [data-clock-target='duration']", "0:40"
      assert_select "[data-testid='break-end-button']:not([disabled])"
    end

    at 2026, 11, 24, 0, 30 do
      post break_end_path
      follow_redirect!
      assert_select ".flash--notice", "休憩を終了しました（00:30）。今回の休憩は 1:00、休憩の合計は 1:00 です。"
      assert_select "[data-testid='break-list'] li", /23:30〜00:30.*1:00/m
    end

    at 2026, 11, 24, 2, 0 do
      post clock_out_path
      follow_redirect!
      assert_select ".flash--notice", "退勤しました（02:00）。11/23(月) の勤務として記録しました（実働 5:00、休憩 1:00）。"
    end
    attendance = @user.attendances.sole
    assert_equal Date.new(2026, 11, 23), attendance.work_date
    assert_equal 60, attendance.break_minutes
  end
end
