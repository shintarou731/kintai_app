require "application_system_test_case"

# シフト作成（F11）をブラウザで通して確かめる：ナビ → シフト表 → マスを開いて登録（パターンから入力・日付をまたぐ）→
# パターンで割り当て（表のスクロール位置を保ったまま更新）→ 前週のコピー → 公開 → 公開後の変更。
# あわせて 375px での表示（ページ全体に横スクロールが出ない）と、スプリント10の評価の指摘（付与の画面）を確かめる。
class ShiftsTest < ApplicationSystemTestCase
  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    @early = ShiftPattern.create!(name: "早番", start_time: "9:00", end_time: "18:00", break_minutes: 60)
    @late = ShiftPattern.create!(name: "遅番", start_time: "13:00", end_time: "22:00", break_minutes: 60)
    @week = Date.current.next_week(:monday)
    @wednesday = @week + 2
  end

  def cell(user, date)
    find("td#shift_cell_#{user.id}_#{date.iso8601}")
  end

  test "マスを開いて登録し、パターンで割り当て、前週をコピーして、週を公開する" do
    log_in_as @admin
    find("summary", text: "管理").click
    within(".nav__menu-list") { click_on "シフト作成" }
    assert_selector "h1", text: "シフト作成"
    click_on "翌週 →"
    assert_selector "[data-testid='week-range']", text: I18n.l(@week, format: :long)

    # マスを開いて、パターンのボタンで入力し、日付をまたぐ時刻に変えて登録する
    cell(@employee, @wednesday).find("a").click
    assert_selector "[data-testid='shift-form-title']", text: "従業 花子 さん"
    find("[data-testid='pattern-fill']", text: "早番").click
    assert_selector "[data-testid='shift-preview']", text: "9:00〜18:00・勤務時間 9:00・実働の予定 8:00"
    find("input[name='shift[start_time]']").set("22:00")
    find("input[name='shift[end_time]']").set("06:00")
    assert_selector "[data-testid='shift-preview']", text: "22:00〜翌6:00・勤務時間 8:00・実働の予定 7:00・日付をまたいで翌日に終わります"
    click_on "登録する"
    assert_text "のシフト（22:00〜翌6:00）を登録しました（下書き）"
    within(cell(@employee, @wednesday)) do
      assert_selector "[data-testid='shift-cell-time']", text: "22:00〜翌6:00"
      assert_selector "[data-testid='shift-state']", text: "下書き"
    end
    assert_selector "[data-testid='shift-day-head'][data-date='#{@wednesday.iso8601}'] [data-testid='shift-day-count']", text: "1人"

    # パターンで割り当て：マスを押すだけで入る。ページの読み込み直しはしない（morph）
    click_on "遅番"
    assert_selector "[data-testid='brush-hint']", text: "マスを押すと「遅番」"
    page.execute_script("window.shiftBoardMarker = 'kept'")
    cell(@employee, @week).find("button").click
    assert_text "に「遅番」（13:00〜22:00）を割り当てました（下書き）"
    within(cell(@employee, @week)) { assert_selector "[data-testid='shift-cell-time']", text: "13:00〜22:00" }
    cell(@admin, @week).find("button").click
    within(cell(@admin, @week)) { assert_selector "[data-testid='shift-cell-time']", text: "13:00〜22:00" }
    assert_equal "kept", page.evaluate_script("window.shiftBoardMarker")
    assert_selector "[data-testid='shift-day-head'][data-date='#{@week.iso8601}'] [data-testid='shift-day-count']", text: "2人"
    click_on "マスを開いて入力"
    page.save_screenshot(Rails.root.join("tmp/screenshots/shifts-board-1400.png"))

    # 公開する
    accept_confirm(/シフトを公開します（追加 3件）/) { click_on "この週を公開" }
    assert_text "のシフトを公開しました（追加 3件）"
    assert_selector "[data-testid='week-status']", text: "公開済み"
    within(cell(@employee, @wednesday)) { assert_no_selector "[data-testid='shift-state']" }

    # 公開後に変更すると、マスと週の状態で分かる
    cell(@employee, @wednesday).find("a").click
    assert_selector "[data-testid='shift-publication-state']", text: "公開済みです"
    find("input[name='shift[end_time]']").set("05:00")
    click_on "変更を保存する"
    assert_text "公開中の内容（22:00〜翌6:00）は、週を「公開」するまで変わりません"
    within(cell(@employee, @wednesday)) do
      assert_selector "[data-testid='shift-state']", text: "変更・未公開"
      assert_selector "[data-testid='shift-cell-published']", text: "公開中 22:00〜翌6:00"
    end
    assert_selector "[data-testid='week-status']", text: "公開後の変更あり（未公開）"

    # 翌週に前週（この週）をコピーする。すでにあるマスは上書きしない
    click_on "翌週 →"
    accept_confirm(/コピーする見込み：3件/) { click_on "前週をコピー" }
    assert_text "のシフトを 3件 コピーしました（下書き）"
    within(cell(@employee, @wednesday + 7)) { assert_selector "[data-testid='shift-cell-time']", text: "22:00〜翌5:00" }
    accept_confirm(/すでにシフトがあるマス 3件/) { click_on "前週をコピー" }
    assert_text "コピーできるマスがありませんでした"
  end

  test "375px：ページ全体に横スクロールを出さず、表の中だけを横にスクロールでき、割り当て後も位置を保つ" do
    Shift.create!(user: @employee, work_date: @week + 6, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    log_in_as @admin

    # 管理メニューは画面の幅に収まり、「シフト作成」がある
    find("summary", text: "管理").click
    menu = find(".nav__menu-list")
    assert menu.has_link?("シフト作成")
    assert_operator menu.evaluate_script("this.getBoundingClientRect().right"), :<=, 375
    assert_no_horizontal_scroll
    within(".nav__menu-list") { click_on "シフト作成" }

    visit admin_shifts_path(week: @week.iso8601, pattern: @early.id)
    assert_selector "[data-testid='shift-table']"
    assert_no_horizontal_scroll
    scroller = find("[data-testid='shift-board-scroll']")
    assert_operator scroller.evaluate_script("this.scrollWidth"), :>, scroller.evaluate_script("this.clientWidth")
    page.save_screenshot(Rails.root.join("tmp/screenshots/shifts-board-375.png"))

    # 表を右端（日曜）までスクロールして割り当てても、スクロールの位置を保つ
    scroller.execute_script("this.scrollLeft = this.scrollWidth")
    left = scroller.evaluate_script("this.scrollLeft")
    assert_operator left, :>, 100
    cell(@admin, @week + 6).find("button").click
    assert_text "に「早番」（9:00〜18:00）を割り当てました"
    within(cell(@admin, @week + 6)) { assert_selector "[data-testid='shift-cell-time']", text: "9:00〜18:00" }
    assert_in_delta left, find("[data-testid='shift-board-scroll']").evaluate_script("this.scrollLeft"), 2
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/shifts-board-375-scrolled.png"))

    visit new_admin_shift_path(user_id: @employee.id, date: (@week + 1).iso8601)
    assert_selector "[data-testid='shift-form']"
    assert_no_horizontal_scroll
    visit admin_shift_patterns_path
    assert_selector "[data-testid='shift-pattern-row']", count: 2
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/shift-patterns-375.png"))
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "375px の付与の画面：「有効」バッジが縦に伸びず、履歴の内容が広い幅で表示される（スプリント10の評価の指摘）" do
    leave = @employee.leave_requests.new(target_date: @wednesday, end_date: @wednesday + 2, leave_type: "paid", day_part: "full_day", reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: Time.current)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    log_in_as @admin
    visit admin_employee_paid_leave_grants_path(@employee)

    badge = first("[data-testid='grant-row'] [data-column='state'] .badge")
    assert_operator badge.evaluate_script("this.getBoundingClientRect().height"), :<, 28
    link = first("[data-testid='paid-leave-history-row'][data-kind='usage'] [data-column='detail'] a")
    line_height = link.evaluate_script("parseFloat(getComputedStyle(this).lineHeight)")
    assert_operator link.evaluate_script("this.getBoundingClientRect().height"), :<=, line_height * 2 + 1
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/paid-leave-grants-375-fixed.png"))
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
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
