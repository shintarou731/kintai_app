require "application_system_test_case"

class WorkRuleSettingsTest < ApplicationSystemTestCase
  test "管理者が管理メニューから設定を開き、不正な値はエラー、正しい値は保存されて勤怠履歴に反映される" do
    today = Time.zone.today
    admin = users(:admin)
    # 今日の前日（今日が1日なら今日）に実働 8:00 の勤務
    worked_on = [ today.yesterday, today.beginning_of_month ].max
    record = admin.attendances.create!(work_date: worked_on, clock_in_at: worked_on.in_time_zone.change(hour: 9),
                                       clock_out_at: worked_on.in_time_zone.change(hour: 18))
    record.breaks.create!(started_at: worked_on.in_time_zone.change(hour: 12), ended_at: worked_on.in_time_zone.change(hour: 13))

    log_in_as admin
    within(".header") do
      find("summary", text: "管理").click
      click_on "設定"
    end
    assert_selector "h1", text: "勤務ルール設定"
    assert_field "1日の所定労働時間", with: "8:00"
    assert_field "標準の休憩時間", with: "1:00"
    assert_select "月の締め日", selected: "月末"
    assert_field "月の残業時間の警告ライン", with: "45"
    page.save_screenshot(Rails.root.join("tmp/screenshots/work-rule-settings-1400.png"))

    # 不正な値はエラー
    fill_in "1日の所定労働時間", with: "25:00"
    fill_in "標準の休憩時間", with: "-1:00"
    click_on "保存する"
    assert_text "1日の所定労働時間は 24:00 以下にしてください"
    assert_text "標準の休憩時間はマイナスにできません"
    assert_field "1日の所定労働時間", with: "25:00"
    assert_equal 0, WorkRuleSetting.count

    # 正しい値は保存される
    fill_in "1日の所定労働時間", with: "7:00"
    fill_in "標準の休憩時間", with: "0:45"
    select "20日", from: "月の締め日"
    fill_in "月の残業時間の警告ライン", with: "40"
    click_on "保存する"
    assert_text "勤務ルールを保存しました（1日の所定労働時間 8:00 → 7:00、標準の休憩時間 1:00 → 0:45、締め日 月末 → 20日、残業時間の警告ライン 45時間 → 40時間）"
    assert_field "1日の所定労働時間", with: "7:00"
    assert_select "月の締め日", selected: "20日"

    # 勤怠履歴：今日が属する20日締めの月度、残業は 8:00 − 7:00 ＝ 1:00
    period = AttendancePeriod.containing(today, closing_day: 20)
    within(".header__nav") { click_on "勤怠履歴" }
    assert_selector "[data-testid='period-label']", text: "#{period.year}年#{period.month}月度"
    assert_selector "[data-testid='period-range']",
                    text: "#{I18n.l(period.start_date, format: :short_with_day)}〜#{I18n.l(period.end_date, format: :short_with_day)}"
    assert_selector "[data-testid='attendance-days'] tbody tr", count: period.dates.size
    if period.include?(worked_on)
      assert_selector "tr[data-date='#{worked_on.iso8601}'] td[data-column='overtime']", text: "1:00"
    end
    assert_selector "[data-testid='monthly-totals']", text: "所定労働時間（7:00）"
    assert_selector "[data-testid='overtime-warning']", text: "警告ライン 40時間"
    page.save_screenshot(Rails.root.join("tmp/screenshots/attendance-history-closing-20.png"))

    # 375px でも横スクロールなし
    visit admin_work_rule_setting_path
    page.current_window.resize_to(375, 812)
    assert_selector "h1", text: "勤務ルール設定"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/work-rule-settings-375.png"))
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "従業員には管理メニューの「設定」が出ず、URL を直接開いてもホームに戻される" do
    log_in_as users(:employee)
    assert_no_selector "[data-testid='admin-menu']"
    visit admin_work_rule_setting_path
    assert_text "この画面を表示する権限がありません。"
    assert_current_path root_path
  end

  private

  def log_in_as(user)
    visit login_path
    fill_in "メールアドレス", with: user.email
    fill_in "パスワード", with: "password123"
    click_on "ログイン"
    assert_text "ログインしました。"
  end

  def assert_no_horizontal_scroll
    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator scroll_width, :<=, client_width
  end
end
