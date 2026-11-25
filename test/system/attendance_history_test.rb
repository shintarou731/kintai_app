require "application_system_test_case"

class AttendanceHistoryTest < ApplicationSystemTestCase
  setup do
    @user = users(:employee)
    today = Time.zone.today
    # 今月の1日に退勤済みの勤務、2日に退勤漏れ（今日が1日・2日のときは前月の勤務になるが、前月へ移動して確かめる）
    @worked_on = today.beginning_of_month
    @missing_on = @worked_on + 1
    @user.attendances.create!(work_date: @worked_on, clock_in_at: @worked_on.in_time_zone.change(hour: 9),
                              clock_out_at: @worked_on.in_time_zone.change(hour: 18, min: 45))
    if @missing_on < today # 勤務日が今日より前なら、退勤していない勤務は退勤漏れ
      @user.attendances.create!(work_date: @missing_on, clock_in_at: @missing_on.in_time_zone.change(hour: 9))
    end
  end

  test "ヘッダーから勤怠履歴を開き、前月・翌月へ移動できる" do
    log_in_as @user
    within(".header__nav") { click_on "勤怠履歴" }

    this_month = Time.zone.today
    assert_selector "[data-testid='period-label']", text: "#{this_month.year}年#{this_month.month}月"
    assert_selector "[data-testid='attendance-days'] tbody tr", count: this_month.end_of_month.day
    assert_selector "tr[data-date='#{@worked_on.iso8601}'] td[data-column='worked']", text: "9:45"
    assert_selector "[data-testid='total-worked']", text: "9:45"
    assert_selector "[data-testid='total-overtime']", text: "1:45"

    # 土曜・日曜は平日と背景色が違う（祝日の土曜・日曜と、祝日の平日は除いて選ぶ）
    saturday = (@worked_on..@worked_on.end_of_month).find { |date| HolidayCalendar.day_kind(date) == :saturday }
    sunday = (@worked_on..@worked_on.end_of_month).find { |date| HolidayCalendar.day_kind(date) == :sunday }
    weekday = (@worked_on..@worked_on.end_of_month).find do |date|
      HolidayCalendar.working_day?(date) && date != this_month && date != @worked_on && date != @missing_on
    end
    colors = [ saturday, sunday, weekday ].map { |date| background_of("tr[data-date='#{date.iso8601}']") }
    assert_equal 3, colors.uniq.size, "土曜・日曜・平日の背景色は別の色のはず: #{colors.inspect}"
    page.save_screenshot(Rails.root.join("tmp/screenshots/attendance-history-1400.png"))

    if @user.attendances.exists?(work_date: @missing_on)
      assert_selector "tr[data-date='#{@missing_on.iso8601}'] .badge--danger", text: "退勤漏れ"
      assert_selector "[data-testid='missing-clock-out-notice']", text: "退勤漏れが 1 日あります"
    end

    click_on "← 前月"
    previous = this_month.prev_month
    assert_selector "[data-testid='period-label']", text: "#{previous.year}年#{previous.month}月"
    assert_selector "[data-testid='attendance-days'] tbody tr", count: previous.end_of_month.day
    click_on "翌月 →"
    assert_selector "[data-testid='period-label'] .badge", text: "今月"
    click_on "翌月 →"
    click_on "今月"
    assert_selector "[data-testid='period-label'] .badge", text: "今月"
  end

  test "スマートフォン幅（375px）では日ごとのカード表示になり、横スクロールが出ない" do
    page.current_window.resize_to(375, 812)
    log_in_as @user
    visit attendances_path

    assert_selector "[data-testid='attendance-days']"
    assert_no_horizontal_scroll
    # 見出し行は隠れ、各欄の名前（出勤・実働など）が値と一緒に出る
    assert_no_selector "[data-testid='attendance-days'] thead", visible: true
    worked_cell = "tr[data-date='#{@worked_on.iso8601}'] td[data-column='worked']"
    assert_selector worked_cell, text: "9:45"
    label = page.evaluate_script("getComputedStyle(document.querySelector(#{worked_cell.to_json}), '::before').content")
    assert_equal '"実働"', label
    # 勤務の無い日は「勤務なし」の1行に縮む（祝日の行は祝日名を出すので、祝日ではない日で確かめる）
    empty_date = (@worked_on..@worked_on.end_of_month).find do |date|
      !@user.attendances.exists?(work_date: date) && !HolidayCalendar.holiday?(date)
    end
    assert_selector "tr[data-date='#{empty_date.iso8601}']", text: "勤務なし"
    page.execute_script("document.querySelector('[data-testid=attendance-days]').scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/screenshots/attendance-history-375.png"))
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "祝日の行は日曜と同じ赤で祝日名が出て、祝日ではない土曜（青）と見分けられる。375px のカード表示でも祝日名が出る" do
    log_in_as @user
    visit attendances_path(month: "2026-11")
    holiday_row = "tr[data-date='2026-11-23']"
    assert_selector "#{holiday_row} [data-testid='holiday-name']", text: "勤労感謝の日"
    holiday_color = background_of(holiday_row)
    assert_equal background_of("tr[data-date='2026-11-22']"), holiday_color, "祝日は日曜と同じ色"
    assert_not_equal background_of("tr[data-date='2026-11-21']"), holiday_color, "祝日ではない土曜は別の色"
    assert_not_equal background_of("tr[data-date='2026-11-24']"), holiday_color, "平日は別の色"
    day_color = page.evaluate_script("getComputedStyle(document.querySelector(\"#{holiday_row} .history-table__day\")).color")
    assert_equal page.evaluate_script("getComputedStyle(document.querySelector(\"tr[data-date='2026-11-22'] .history-table__day\")).color"), day_color
    page.execute_script("document.querySelector(\"#{holiday_row}\").scrollIntoView({ block: 'center' })")
    page.save_screenshot(Rails.root.join("tmp/screenshots/history-holiday-1400.png"))

    # 土曜の祝日（2028年1月1日・元日）は祝日の色
    visit attendances_path(month: "2028-01")
    assert_selector "tr[data-date='2028-01-01'] [data-testid='holiday-name']", text: "元日"
    assert_equal background_of("tr[data-date='2028-01-02']"), background_of("tr[data-date='2028-01-01']")
    assert_not_equal background_of("tr[data-date='2028-01-08']"), background_of("tr[data-date='2028-01-01']")

    # 375px：カード表示でも祝日名が日付の横に見え、横スクロールが出ない
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit attendances_path(month: "2026-11")
    assert_selector "#{holiday_row} [data-testid='holiday-name']", text: "勤労感謝の日", visible: true
    assert_equal background_of("tr[data-date='2026-11-22']"), background_of(holiday_row)
    assert_no_horizontal_scroll
    page.execute_script("document.querySelector(\"#{holiday_row}\").scrollIntoView({ block: 'center' })")
    page.save_screenshot(Rails.root.join("tmp/screenshots/history-holiday-375.png"))
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "開発用（DEV_NOW）の注意書きの時刻は表示後も進む" do
    DevelopmentClock.offset = 0
    log_in_as @user
    visit attendances_path
    banner_time = find("[data-testid='dev-clock-banner'] [data-clock-target='time']")
    first_text = banner_time.text
    assert_match(/\A\d{2}:\d{2}:\d{2}\z/, first_text)
    assert_no_selector "[data-testid='dev-clock-banner'] [data-clock-target='time']", exact_text: first_text, wait: 3
  ensure
    DevelopmentClock.offset = nil
  end

  private

  def background_of(selector)
    page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).backgroundColor")
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
