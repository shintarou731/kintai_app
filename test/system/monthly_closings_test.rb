require "application_system_test_case"

# 月次集計と締め（F14）をブラウザで確かめる：管理メニューから開く／確認ダイアログを経て締める・解除する／
# 日別の勤怠から直接修正する（休憩の行を JS で足す）／1400px・375px で横スクロールが出ない
class MonthlyClosingsTest < ApplicationSystemTestCase
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 12, 5, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    date = Date.new(2026, 11, 10)
    attendance = Attendance.create!(user: @employee, work_date: date, clock_in_at: date.in_time_zone.change(hour: 9),
                                    clock_out_at: date.in_time_zone.change(hour: 19))
    attendance.breaks.create!(started_at: date.in_time_zone.change(hour: 12), ended_at: date.in_time_zone.change(hour: 13))
    Attendance.create!(user: @employee, work_date: Date.new(2026, 11, 26), clock_in_at: Time.zone.local(2026, 11, 26, 9))
  end

  teardown do
    reset_size
    travel_back
  end

  test "月次集計を開き、確認ダイアログを経て締め、解除できる" do
    log_in_as @admin
    find("[data-testid='admin-menu'] summary").click
    find("[data-testid='nav-monthly']").click
    assert_selector "h1", text: "月次集計"
    click_on "← 前月"
    assert_selector "[data-testid='period-label']", text: "2026年11月"
    assert_selector "[data-testid='warning-missing']", text: "退勤漏れ 1件"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/monthly-summary-1400.png"))

    message = dismiss_confirm { click_on "2026年11月を締める" }
    assert_match "2026年11月（11/1(日)〜11/30(月)）を締めますか？退勤漏れ 1件", message
    assert_equal 0, MonthlyClosing.count

    accept_confirm { click_on "2026年11月を締める" }
    assert_text "を締めました"
    assert_selector "[data-testid='closing-status'][data-status='closed']"
    assert_equal 1, MonthlyClosing.active.count

    accept_confirm { click_on "締めを解除する" }
    assert_text "締めを解除しました"
    assert_selector "[data-testid='closing-status'][data-status='open']"
    assert_selector "[data-testid='closing-history-row'] [data-column='reopened']", text: "管理 太郎"
  end

  test "日別の勤怠から、退勤漏れの日に退勤と休憩を入れて直す。375px でも横スクロールが出ない" do
    resize_to(375)
    log_in_as @admin
    visit admin_monthly_summaries_path(month: "2026-11")
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/monthly-summary-375.png"))
    find("[data-testid='monthly-summary-row'][data-user-id='#{@employee.id}'] [data-testid='monthly-detail-link']").click
    assert_selector "[data-testid='monthly-user-title']", text: "従業 花子"
    assert_no_horizontal_scroll

    find("tr[data-date='2026-11-26'] [data-testid='admin-edit-link']").click
    assert_selector "h1", text: "勤怠の直接修正"
    assert_no_horizontal_scroll
    fill_in "attendance_record_editor_clock_out_time", with: "18:00"
    find("[data-testid='add-break']").click if all("[data-testid='break-row']").empty?
    within(all("[data-testid='break-row']").first) do
      all("input[type='time']")[0].fill_in(with: "12:00")
      all("input[type='time']")[1].fill_in(with: "13:00")
    end
    fill_in "attendance_record_editor_reason", with: "本人から 18:00 に退勤したと連絡"
    page.save_screenshot(Rails.root.join("tmp/screenshots/attendance-record-edit-375.png"))
    click_on "修正を保存する"
    assert_text "勤怠を修正しました"
    assert_selector "tr[data-date='2026-11-26'] [data-column='worked']", text: "8:00"
    assert_selector "[data-testid='attendance-edit-row'] [data-column='reason']", text: "本人から 18:00 に退勤したと連絡"
    assert_no_horizontal_scroll
  end

  private

  def resize_to(width)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
  end

  def reset_size
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def assert_no_horizontal_scroll
    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator scroll_width, :<=, client_width
  end
end
