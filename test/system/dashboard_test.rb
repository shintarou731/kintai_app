require "application_system_test_case"

# 管理者のダッシュボード（F13）をブラウザで確かめる：管理メニューから開く、遅れの行が赤い、退勤漏れの一覧へ移る、
# 1400px・375px で横スクロールが出ない。あわせてスプリント12の指摘（1280px で「次回のシフト」が折り返さない）を確かめる
class DashboardTest < ApplicationSystemTestCase
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-25（水）10:00
  NOW = Time.zone.local(2026, 11, 25, 10, 0)
  TODAY = NOW.to_date

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
  end

  teardown do
    reset_size
    travel_back
  end

  def at(date, hour, minute = 0)
    Time.zone.local(date.year, date.month, date.day, hour, minute)
  end

  def published!(user, date, start_time, end_time)
    shift = Shift.create!(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: 60)
    shift.publish_draft!(now: NOW - 1.day)
    shift
  end

  def member!(name, number)
    User.create!(name: name, email: "member#{number}@example.com", password: "password123", role: "employee", hired_on: Date.new(2024, 4, 1))
  end

  def build_scene
    late = member!("遅れ 二郎", 1)
    published!(late, TODAY, "9:00", "18:00")
    working = member!("勤務 一郎", 2)
    published!(working, TODAY, "9:00", "18:00")
    Attendance.create!(user: working, work_date: TODAY, clock_in_at: at(TODAY, 8, 58))
    night = member!("夜勤 三郎", 3)
    published!(night, TODAY - 1, "22:00", "6:00")
    Attendance.create!(user: night, work_date: TODAY - 1, clock_in_at: at(TODAY - 1, 22, 0), clock_out_at: at(TODAY, 6, 2))
    Attendance.create!(user: @employee, work_date: TODAY - 3, clock_in_at: at(TODAY - 3, 9, 0))
    (Date.new(2026, 11, 2)..Date.new(2026, 11, 8)).each do |date|
      Attendance.create!(user: working, work_date: date, clock_in_at: at(date, 8, 0), clock_out_at: at(date, 22, 0))
    end
    late
  end

  test "管理メニューの「ダッシュボード」から開き、遅れは赤い行で先頭に出る。退勤漏れの一覧へ移れる" do
    late = build_scene
    log_in_as @admin
    find("[data-testid='admin-menu'] summary").click
    find("[data-testid='nav-dashboard']").click
    assert_selector "h1", text: "ダッシュボード"

    assert_selector "[data-testid='dashboard-count'][data-state='working']", text: "1名"
    assert_selector "[data-testid='dashboard-late-count']", text: "うち遅れ 1名"
    first_row = first("[data-testid='dashboard-row']")
    assert_equal late.id.to_s, first_row["data-user-id"]
    assert_equal "rgb(185, 28, 28)", first_row.find("[data-testid='dashboard-state']").evaluate_script("getComputedStyle(this).backgroundColor")
    assert_equal "rgb(253, 236, 236)", first_row.find("td", match: :first).evaluate_script("getComputedStyle(this).backgroundColor")
    assert_selector "[data-testid='dashboard-overtime-row']", count: 1
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/dashboard-1400.png"))

    find("[data-testid='dashboard-missing-link']").click
    assert_selector "h1", text: "前日以前の退勤漏れ"
    assert_selector "[data-testid='missing-clock-out-row']", count: 1
    click_on "← ダッシュボードに戻る"
    assert_selector "h1", text: "ダッシュボード"
  end

  test "375px：人数は2列、表はカードになり、横スクロールが出ない" do
    build_scene
    resize_to(375)
    log_in_as @admin
    visit admin_dashboard_path
    assert_no_horizontal_scroll
    counts = all("[data-testid='dashboard-count']")
    assert_equal counts[0].evaluate_script("this.getBoundingClientRect().top"), counts[1].evaluate_script("this.getBoundingClientRect().top")
    assert_operator counts[2].evaluate_script("this.getBoundingClientRect().top"), :>, counts[0].evaluate_script("this.getBoundingClientRect().top")
    late_row = first("[data-testid='dashboard-row']")
    assert_operator late_row.evaluate_script("this.getBoundingClientRect().width"), :>, 300
    page.save_screenshot(Rails.root.join("tmp/screenshots/dashboard-375.png"))
    late_row.evaluate_script("this.scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/screenshots/dashboard-375-table.png"))
    # 備考の無い人のカードには、空の「備考」の段を出さない（スプリント13の評価の指摘1）
    empty_notes = all("td.dashboard-table__note--empty", visible: :all)
    assert_operator empty_notes.size, :>, 0
    empty_notes.each { |cell| assert_equal "none", cell.evaluate_script("getComputedStyle(this).display") }

    # 日付をまたいで勤務中の人の「本人が退勤できます（〜期限）」は、カードの幅で折り返して最後まで読める（指摘2）
    overnight = member!("夜勤 四郎", 4)
    Attendance.create!(user: overnight, work_date: TODAY - 1, clock_in_at: at(TODAY - 1, 23, 58))
    visit admin_missing_clock_outs_path
    assert_no_horizontal_scroll
    badge = find("[data-testid='missing-open']", text: "本人が退勤できます（〜11/25(水) 23:58）")
    row = badge.find(:xpath, "ancestor::tr")
    assert_operator badge.evaluate_script("this.getBoundingClientRect().right"), :<=, row.evaluate_script("this.getBoundingClientRect().right")
    assert_operator badge.evaluate_script("this.scrollWidth"), :<=, badge.evaluate_script("this.clientWidth")
    page.save_screenshot(Rails.root.join("tmp/screenshots/missing-clock-outs-375.png"))
  end

  test "1280px：シフト画面の「次回のシフト」の「22:00〜翌6:00」は1行に収まる（スプリント12の指摘）" do
    published!(@employee, TODAY + 1, "22:00", "6:00")
    resize_to(1280)
    log_in_as @employee
    visit shifts_path
    range = find("[data-testid='shift-next-range']", text: "22:00〜翌6:00")
    line_height = range.evaluate_script("parseFloat(getComputedStyle(this).lineHeight) || 30")
    assert_operator range.evaluate_script("this.getBoundingClientRect().height"), :<, line_height * 1.5
    assert_equal "nowrap", range.evaluate_script("getComputedStyle(this).whiteSpace")
  end

  private

  def resize_to(width)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
  end

  def reset_size
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

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
