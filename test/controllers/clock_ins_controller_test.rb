require "test_helper"

class ClockInsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:employee)
  end

  test "未ログインでは打刻できない" do
    assert_no_difference("Attendance.count") { post clock_in_path }
    assert_redirected_to login_path
  end

  test "出勤するとその時刻が記録され、時刻入りのメッセージが出る" do
    travel_to Time.zone.local(2026, 11, 24, 9, 2, 45) do
      sign_in_as @user
      assert_difference("@user.attendances.count", 1) { post clock_in_path }
      assert_redirected_to root_path
      follow_redirect!
      assert_select ".flash--notice", "出勤しました（09:02）"
      assert_select "[data-testid='time-clock-status']", "勤務中"
      assert_select "[data-testid='clock-in-time']", "09:02"
    end
    assert_equal Time.zone.local(2026, 11, 24, 9, 2, 45), @user.attendances.sole.clock_in_at
  end

  test "出勤を2回送っても（二重クリック・戻って再送信）1件だけ記録される" do
    travel_to Time.zone.local(2026, 11, 24, 9, 0) do
      sign_in_as @user
      post clock_in_path
      assert_no_difference("Attendance.count") { post clock_in_path }
      assert_redirected_to root_path
      follow_redirect!
      assert_select ".flash--alert", /すでに出勤しています（09:00 に出勤）/
      assert_select ".flash--notice", count: 0
    end
  end

  test "退勤済みの日に出勤を送るとエラーになる" do
    travel_to Time.zone.local(2026, 11, 24, 9, 0) do
      sign_in_as @user
      post clock_in_path
    end
    travel_to(Time.zone.local(2026, 11, 24, 18, 0)) { post clock_out_path }

    travel_to Time.zone.local(2026, 11, 24, 19, 0) do
      assert_no_difference("Attendance.count") { post clock_in_path }
      follow_redirect!
      assert_select ".flash--alert", /本日はすでに退勤済みのため、出勤できません/
    end
  end

  test "打刻の結果画面を再読み込み（GET）しても打刻は増えない" do
    travel_to Time.zone.local(2026, 11, 24, 9, 0) do
      sign_in_as @user
      post clock_in_path
      follow_redirect!
      assert_no_difference("Attendance.count") { get root_path }
      assert_response :success
    end
  end
end
