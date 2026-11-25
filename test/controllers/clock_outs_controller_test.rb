require "test_helper"

class ClockOutsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:employee)
  end

  test "未ログインでは退勤できない" do
    post clock_out_path
    assert_redirected_to login_path
  end

  test "退勤すると時刻と実働時間が記録・表示される" do
    travel_to(Time.zone.local(2026, 11, 24, 9, 0)) do
      sign_in_as @user
      post clock_in_path
    end

    travel_to Time.zone.local(2026, 11, 24, 17, 45, 30) do
      post clock_out_path
      assert_redirected_to root_path
      follow_redirect!
      assert_select ".flash--notice", "退勤しました（17:45）。本日の実働時間は 8:45 です。"
      assert_select "[data-testid='time-clock-status']", "退勤済み"
      assert_select "[data-testid='clock-out-time']", "17:45"
      assert_select "[data-testid='worked-time']", "8:45"
      assert_select "[data-testid='clock-in-button'][disabled]"
      assert_select "[data-testid='clock-out-button'][disabled]"
    end
    assert_equal Time.zone.local(2026, 11, 24, 17, 45, 30), @user.attendances.sole.clock_out_at
  end

  test "退勤を2回送っても最初の退勤時刻のまま" do
    travel_to(Time.zone.local(2026, 11, 24, 9, 0)) do
      sign_in_as @user
      post clock_in_path
    end
    travel_to(Time.zone.local(2026, 11, 24, 18, 0)) { post clock_out_path }

    travel_to Time.zone.local(2026, 11, 24, 18, 0, 2) do
      post clock_out_path
      follow_redirect!
      assert_select ".flash--alert", "すでに退勤しています（18:00 に退勤）。"
    end
    assert_equal Time.zone.local(2026, 11, 24, 18, 0), @user.attendances.sole.clock_out_at
  end

  test "出勤していないと退勤できない" do
    sign_in_as @user
    post clock_out_path
    follow_redirect!
    assert_select ".flash--alert", /出勤していないため、退勤できません/
    assert_equal 0, @user.attendances.count
  end

  test "22:00 出勤 → 翌 2:00 退勤：翌日のホーム画面で退勤でき、出勤した日の勤務になる" do
    travel_to Time.zone.local(2026, 11, 23, 22, 0) do
      sign_in_as @user
      post clock_in_path
    end

    travel_to Time.zone.local(2026, 11, 24, 1, 58) do
      get root_path
      assert_select "[data-testid='time-clock-status']", "勤務中"
      assert_select "[data-testid='clock-out-button']:not([disabled])"
      assert_select "[data-testid='clock-in-button'][disabled]"
      assert_select "[data-testid='overnight-note']", /11\/23\(月\) 22:00 に出勤した勤務の続きです/
      assert_select "[data-testid='today-attendance'] h2", /11\/23\(月\) の勤務/
      assert_select "[data-testid='worked-time']", /3:58/
    end

    travel_to Time.zone.local(2026, 11, 24, 2, 0) do
      post clock_out_path
      follow_redirect!
      assert_select ".flash--notice", "退勤しました（02:00）。11/23(月) の勤務として記録しました（実働 4:00）。"
      # 11/24 分はまだ出勤していないので出勤できる。前日の勤務は参考表示
      assert_select "[data-testid='time-clock-status']", "未出勤"
      assert_select "[data-testid='clock-in-button']:not([disabled])"
      assert_select "[data-testid='previous-attendance']", /22:00〜02:00.*実働 4:00/m
    end

    attendance = @user.attendances.sole
    assert_equal Date.new(2026, 11, 23), attendance.work_date
    assert_equal Time.zone.local(2026, 11, 24, 2, 0), attendance.clock_out_at
  end

  test "日付をまたいだ勤務の退勤を二重に送ると「すでに退勤」、その日の夜に送ると「出勤していない」と案内する" do
    travel_to Time.zone.local(2026, 11, 23, 22, 0) do
      sign_in_as @user
      post clock_in_path
    end
    attendance_id = @user.attendances.sole.id

    travel_to(Time.zone.local(2026, 11, 24, 2, 0)) { post clock_out_path, params: { attendance_id: attendance_id } }
    travel_to Time.zone.local(2026, 11, 24, 2, 0, 1) do
      # 退勤ボタンのダブルクリック・戻って再送信（画面に出ていた勤務の ID が届く）
      post clock_out_path, params: { attendance_id: attendance_id }
      follow_redirect!
      assert_select ".flash--alert", "すでに退勤しています（02:00 に退勤）。"
    end

    travel_to Time.zone.local(2026, 11, 24, 19, 1) do
      # 11/24 は未出勤（ボタンは押せない）。前日の勤務の退勤時刻は理由にしない
      get root_path
      assert_select "[data-testid='clock-out-button'][disabled]"
      post clock_out_path
      follow_redirect!
      assert_select ".flash--alert", "出勤していないため、退勤できません。先に出勤を打刻してください。"
    end
    assert_equal Time.zone.local(2026, 11, 24, 2, 0), @user.attendances.sole.clock_out_at
  end

  test "勤務中の退勤ボタンは表示中の勤務の ID を送る" do
    travel_to Time.zone.local(2026, 11, 24, 9, 0) do
      sign_in_as @user
      post clock_in_path
      get root_path
      assert_select "form[action='#{clock_out_path}'] input[name='attendance_id'][value='#{@user.attendances.sole.id}']"
    end
  end
end
