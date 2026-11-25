require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  test "未ログインでホームにアクセスするとログイン画面へ移動する" do
    get root_path
    assert_redirected_to login_path
    follow_redirect!
    assert_select ".flash--alert", "ログインしてください。"
  end

  test "存在しないユーザーIDのセッションは未ログインとして扱う" do
    sign_in_as users(:employee)
    users(:employee).destroy
    get root_path
    assert_redirected_to login_path
  end

  test "管理者でログインするとヘッダーに氏名と管理者の表示が出る" do
    sign_in_as users(:admin)
    get root_path
    assert_response :success
    assert_select ".header__user-name", "管理 太郎"
    assert_select ".header__user .badge", "管理者"
    assert_select "form[action='#{logout_path}'] button", "ログアウト"
  end

  test "ホーム画面の最下部に「アカウント」欄（各画面へのリンクの一覧）が出ない。移動はヘッダーから行う" do
    [ users(:employee), users(:admin) ].each do |user|
      sign_in_as user
      get root_path
      assert_response :success
      assert_select "main h2", text: "アカウント", count: 0
      assert_select ".quick-links", count: 0
      assert_select "main a[href='#{edit_password_path}']", count: 0
      assert_select "[data-testid='home-dashboard-link'], [data-testid='home-approvals-link']", count: 0
      # 移動先へはヘッダーから行ける
      assert_select ".header [data-testid='header-settings'][href='#{account_path}']"
      assert_select ".header__nav a[href='#{approval_requests_path}']"
      if user.admin?
        assert_select "[data-testid='admin-menu'] a[href='#{admin_dashboard_path}']"
        assert_select "[data-testid='admin-menu'] a[href='#{admin_approval_requests_path}']"
        assert_select "[data-testid='admin-menu'] a[href='#{admin_shift_reports_path}']"
        assert_select "[data-testid='admin-menu'] a[href='#{admin_work_rule_setting_path}']"
      end
      delete logout_path
    end
  end

  test "従業員でログインするとヘッダーに氏名が出て、管理者の表示は出ない" do
    sign_in_as users(:employee)
    get root_path
    assert_response :success
    assert_select ".header__user-name", "従業 花子"
    assert_select ".header__user .badge", count: 0
  end

  test "ホーム画面に現在の日付と時刻（秒まで・日本時間）と未出勤の状態が出る" do
    travel_to Time.utc(2026, 11, 24, 0, 2, 5) do # = 11/24 09:02:05 JST
      sign_in_as users(:employee)
      get root_path
      assert_select ".punch__date", "2026年11月24日(火)"
      assert_select "[data-testid='current-time'] time", "09:02:05"
      assert_select "[data-controller='clock'][data-clock-server-now-value='#{Time.current.to_i * 1000}']"
      assert_select "[data-testid='time-clock-status']", "未出勤"
      assert_select "[data-testid='clock-in-button']:not([disabled])", "出勤"
      assert_select "[data-testid='clock-out-button'][disabled]", "退勤"
      assert_select "[data-testid='clock-in-time']", "--:--"
      assert_select "[data-testid='clock-out-time']", "--:--"
      assert_select "[data-testid='worked-time']", "0:00"
      assert_select "[data-testid='missing-clock-outs']", count: 0
    end
  end

  test "勤務中は経過した実働時間を表示し、出勤ボタンは押せない" do
    users(:employee).attendances.create!(work_date: Date.new(2026, 11, 24), clock_in_at: Time.zone.local(2026, 11, 24, 9, 0))
    travel_to Time.zone.local(2026, 11, 24, 10, 15, 40) do
      sign_in_as users(:employee)
      get root_path
      assert_select "[data-testid='time-clock-status']", "勤務中"
      assert_select "[data-testid='clock-in-button'][disabled]"
      assert_select "[data-testid='clock-out-button']:not([disabled])"
      assert_select "[data-testid='worked-time'] [data-clock-target='duration']", "1:15"
    end
  end

  test "退勤の打刻がない過去の勤務があると注意を出す" do
    users(:employee).attendances.create!(work_date: Date.new(2026, 11, 20), clock_in_at: Time.zone.local(2026, 11, 20, 9, 0))
    travel_to Time.zone.local(2026, 11, 24, 9, 0) do
      sign_in_as users(:employee)
      get root_path
      assert_select "[data-testid='missing-clock-outs']", /11\/20\(金\)（09:00 出勤）/
      assert_select "[data-testid='missing-clock-outs'] .notice-box__title", "退勤漏れの勤務があります"
      assert_select "[data-testid='time-clock-status']", "未出勤"
    end
  end

  test "退勤漏れのお知らせのリンクは、退勤漏れの勤務がある月の勤怠履歴を開く" do
    user = users(:employee)
    user.attendances.create!(work_date: Date.new(2026, 10, 31), clock_in_at: Time.zone.local(2026, 10, 31, 9, 0))
    travel_to Time.zone.local(2026, 11, 2, 9, 0) do
      sign_in_as user
      get root_path
      october = attendances_path(month: "2026-10")
      assert_select "[data-testid='missing-clock-outs-history-link'][href=?]", october, text: "勤怠履歴で確認する"
      assert_select "[data-testid='missing-clock-out-link'][href=?]", october, text: "10/31(土)（09:00 出勤）"

      get october
      assert_select "tr[data-date='2026-10-31'] [data-testid='day-status']", "退勤漏れ"
    end
  end

  test "退勤漏れが複数の月にあるときは、日ごとにその月の勤怠履歴へのリンクを出す" do
    user = users(:employee)
    user.attendances.create!(work_date: Date.new(2026, 10, 30), clock_in_at: Time.zone.local(2026, 10, 30, 9, 0))
    user.attendances.create!(work_date: Date.new(2026, 11, 1), clock_in_at: Time.zone.local(2026, 11, 1, 9, 0))
    travel_to Time.zone.local(2026, 11, 3, 9, 0) do
      sign_in_as user
      get root_path
      november = attendances_path(month: "2026-11")
      october = attendances_path(month: "2026-10")
      assert_select "[data-testid='missing-clock-out-link'][href=?]", november, text: "11/1(日)（09:00 出勤）"
      assert_select "[data-testid='missing-clock-out-link'][href=?]", october, text: "10/30(金)（09:00 出勤）"
      assert_select "[data-testid='missing-clock-outs-history-link'][href=?]", november
    end
  end

  test "日付をまたいだ勤務中は、退勤できる期限と、履歴では退勤漏れと表示されることを案内する" do
    user = users(:employee)
    user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: Time.zone.local(2026, 11, 10, 10, 0))
    travel_to Time.zone.local(2026, 11, 11, 9, 59) do
      sign_in_as user
      get root_path
      assert_select "[data-testid='time-clock-status']", "勤務中"
      assert_select "[data-testid='clock-out-button']:not([disabled])"
      assert_select "[data-testid='overnight-note']", /出勤から24時間以内（11\/11\(水\) 10:00 まで）なら打刻できます。/
      assert_select "[data-testid='overnight-note']", /退勤するまで、勤怠履歴では「退勤漏れ」と表示されます。/
      assert_select "[data-testid='missing-clock-outs']", count: 0
    end
  end
end
