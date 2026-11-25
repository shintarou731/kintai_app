require "application_system_test_case"

# シフト確認と予実比較（F12）をブラウザで確かめる：ナビの「シフト」→ 月のカレンダー（1400px・375px）、
# 勤怠履歴の予定と実績（375px のカード表示）、管理者の予実の確認。
# あわせてスプリント11の評価の指摘（公開の履歴のバッジ・割り当て後に表がずれない・無効な従業員の入力画面）を確かめる。
class ShiftChecksTest < ApplicationSystemTestCase
  setup do
    @admin = users(:admin)
    @employee = users(:employee)
  end

  def published!(date, start_time, end_time, user: @employee)
    shift = Shift.create!(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: 60)
    shift.publish_draft!(now: Time.current)
    shift
  end

  test "従業員：ナビの「シフト」から公開済みのシフトをカレンダーで見て、勤怠履歴で予定と実績を比べる" do
    past = Date.current - 1
    published!(past, "9:00", "18:00")
    Attendance.create!(user: @employee, work_date: past, clock_in_at: past.in_time_zone.change(hour: 9, min: 7),
                       clock_out_at: past.in_time_zone.change(hour: 18, min: 0))
    published!(past - 1, "22:00", "6:00")
    draft = Shift.create!(user: @employee, work_date: Date.current + 2, start_time: "9:00", end_time: "18:00", break_minutes: 60)

    log_in_as @employee
    find("[data-testid='nav-my-shifts']").click
    # 月の初日（昨日が前月）でも、ナビの移動が終わるのを待ってから次の visit に進む
    assert_selector "[data-testid='calendar-day']"
    assert_selector "h1", text: "#{past.year}年#{past.month}月" if past.month == Date.current.month
    visit shifts_path(month: past.strftime("%Y-%m"))
    within("[data-testid='calendar-day'][data-date='#{past.iso8601}']") do
      assert_selector "[data-testid='calendar-shift']", text: "9:00〜18:00"
      assert_selector "[data-testid='shift-mark'][data-mark='late']", text: "遅刻 0:07"
    end
    within("[data-testid='calendar-day'][data-date='#{(past - 1).iso8601}']") do
      assert_selector "[data-testid='calendar-shift']", text: "22:00〜翌6:00"
      assert_selector "[data-testid='shift-mark'][data-mark='absent']", text: "欠勤"
    end
    if draft.work_date.month == past.month
      assert_no_selector "[data-testid='calendar-day'][data-date='#{draft.work_date.iso8601}'] [data-testid='calendar-shift']"
    end
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/shift-calendar-1400.png"))

    visit attendances_path(month: past.strftime("%Y-%m"))
    within("tr[data-date='#{past.iso8601}']") do
      assert_selector "[data-testid='day-shift']", text: "9:00〜18:00"
      assert_selector "[data-column='clock-in']", text: "09:07"
      assert_selector "[data-testid='shift-mark']", text: "遅刻 0:07"
    end
  end

  test "375px：シフトのカレンダーは1日1行、勤怠履歴のカードに予定と印が出る。ページに横スクロールは出ない" do
    holiday = Date.new(2026, 11, 23)
    published!(holiday, "9:00", "18:00")
    published!(Date.new(2026, 11, 26), "22:00", "6:00")
    Shift.find_by!(work_date: holiday).tap { |shift| shift.update!(start_time: "10:00") }.publish_draft!(now: Time.current)
    resize_to(375)
    log_in_as @employee

    visit shifts_path(month: "2026-11")
    assert_no_horizontal_scroll
    day = find("[data-testid='calendar-day'][data-date='2026-11-23']")
    assert_includes day[:class], "shift-calendar__day--holiday"
    within(day) do
      assert_selector "[data-testid='holiday-name']", text: "勤労感謝の日"
      assert_selector "[data-testid='calendar-shift']", text: "10:00〜18:00"
      assert_selector "[data-testid='shift-revised']", text: "変更あり"
    end
    # 祝日の赤は日曜と同じ色
    sunday_color = find("[data-testid='calendar-day'][data-date='2026-11-29'] .shift-calendar__number").evaluate_script("getComputedStyle(this).color")
    assert_equal sunday_color, day.find(".shift-calendar__number").evaluate_script("getComputedStyle(this).color")
    # 1日1行：日付ごとのカードが画面の幅いっぱいに並ぶ
    assert_operator day.evaluate_script("this.getBoundingClientRect().width"), :>, 300
    assert_selector "[data-testid='calendar-day'][data-date='2026-11-26'] [data-testid='calendar-shift']", text: "22:00〜翌6:00"
    page.save_screenshot(Rails.root.join("tmp/screenshots/shift-calendar-375.png"))

    visit attendances_path(month: "2026-11")
    assert_no_horizontal_scroll
    row = find("tr[data-date='2026-11-26']")
    shift_cell = row.find("[data-column='shift']")
    assert shift_cell.visible?
    assert_includes shift_cell.text, "22:00〜翌6:00"
    if Date.new(2026, 11, 23) < Date.current
      holiday_row = find("tr[data-date='2026-11-23']")
      assert holiday_row.find("[data-testid='shift-mark'][data-mark='absent']").visible?
    end
    page.save_screenshot(Rails.root.join("tmp/screenshots/attendance-history-shift-375.png"))
  ensure
    reset_size
  end

  test "管理者：予実の確認で従業員ごとの回数を見て、日ごとの予定と実績を開く（375px でも崩れない）" do
    past = Date.current - 1
    published!(past, "9:00", "18:00")
    month = WorkRules.current.period_containing(past).to_param
    log_in_as @admin
    find("summary", text: "管理").click
    within(".nav__menu-list") { click_on "予実の確認" }
    assert_selector "h1", text: "予実の確認"
    visit admin_shift_reports_path(month: month)
    row = find("[data-testid='shift-report-row'][data-user-id='#{@employee.id}']")
    assert_selector "[data-testid='shift-report-row'][data-user-id='#{@employee.id}'] [data-column='absent']", text: "1回"
    row.click_on "日ごとに見る"
    assert_selector "[data-testid='report-user-title']", text: "従業 花子 さん"
    assert_selector "[data-testid='report-day'][data-date='#{past.iso8601}'] [data-testid='shift-mark']", text: "欠勤"

    resize_to(375)
    visit admin_shift_reports_path
    assert_no_horizontal_scroll
    badge = first("[data-testid='shift-report-row'] .table__primary")
    assert badge.visible?
    page.save_screenshot(Rails.root.join("tmp/screenshots/shift-reports-375.png"))
  ensure
    reset_size
  end

  test "スプリント11の指摘：375px の公開の履歴でバッジが楕円にならない。割り当ての後も表の位置がずれない" do
    week = Date.current.next_week(:monday)
    early = ShiftPattern.create!(name: "早番", start_time: "9:00", end_time: "18:00", break_minutes: 60)
    shift = Shift.create!(user: @employee, work_date: week, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    ShiftWeekPublication.new(week_start: week, admin: @admin).save
    shift.reload.update!(start_time: "10:00")
    ShiftWeekPublication.new(week_start: week, admin: @admin).save

    resize_to(375)
    log_in_as @admin
    visit admin_shifts_path(week: week.iso8601)
    badge = first("[data-testid='shift-publication'] .badge")
    assert_operator badge.evaluate_script("this.getBoundingClientRect().height"), :<, 28
    # 内容（「変更 1件」とバッジ）は、文字が細く折り返さず、2行以内に収まる
    content = first("[data-testid='shift-publication'] td[data-label='内容']")
    assert_operator content.evaluate_script("this.getBoundingClientRect().height"), :<=, 52
    page.save_screenshot(Rails.root.join("tmp/screenshots/shift-publications-375.png"))
    reset_size

    # 割り当てを続けても、表の位置（ページ上の上端）が変わらない（メッセージは画面上部に重ねて出す）
    visit admin_shifts_path(week: week.iso8601, pattern: early.id)
    table_top = -> { find("[data-testid='shift-table']").evaluate_script("this.getBoundingClientRect().top + window.scrollY") }
    before = table_top.call
    find("td#shift_cell_#{@admin.id}_#{(week + 1).iso8601} button").click
    assert_selector "[data-testid='toast']", text: "「早番」（9:00〜18:00）を割り当てました"
    assert_in_delta before, table_top.call, 1
    find("td#shift_cell_#{@admin.id}_#{(week + 2).iso8601} button").click
    assert_selector "td#shift_cell_#{@admin.id}_#{(week + 2).iso8601} [data-testid='shift-cell-time']", text: "9:00〜18:00"
    assert_in_delta before, table_top.call, 1
    find("[data-testid='toast'] .toast__close").click
    assert_no_selector "[data-testid='toast']"
  ensure
    reset_size
  end

  test "スプリント11の指摘：無効な従業員のシフトの画面は、入力欄と保存のボタンが押せない" do
    inactive = users(:inactive_employee)
    shift = Shift.new(user: inactive, work_date: Date.current + 1, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    shift.save!(validate: false)
    log_in_as @admin
    visit edit_admin_shift_path(shift)
    assert_selector "[data-testid='shift-locked-note']"
    assert find("input[name='shift[start_time]']").disabled?
    assert find("[data-testid='shift-submit']").disabled?
    assert_selector "[data-testid='shift-delete']:not([disabled])"
  end

  private

  def resize_to(width)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 812, deviceScaleFactor: 1, mobile: false)
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
