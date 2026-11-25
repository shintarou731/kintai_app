require "application_system_test_case"

class ApprovalsTest < ApplicationSystemTestCase
  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    # 2日前の退勤漏れ（09:00 出勤）を、退勤 18:00・休憩 12:00〜13:00 に直す申請
    @date = Time.zone.today - 2
    @employee.attendances.create!(work_date: @date, clock_in_at: @date.in_time_zone.change(hour: 9))
    @request = @employee.attendance_correction_requests.new(
      target_date: @date, clock_in_time: "09:00", clock_out_time: "18:00", reason: "退勤の打刻を忘れました。",
      break_inputs: { "0" => { start_time: "12:00", end_time: "13:00" } }
    )
    assert @request.submit, @request.errors.full_messages.inspect
    @date_label = I18n.l(@date, format: :short_with_day)
  end

  test "管理者がナビの件数を見て承認画面を開き、却下のコメント必須を確かめてから承認し、申請者の画面と勤怠履歴に反映される" do
    log_in_as @admin
    assert_selector "[data-testid='admin-menu-badge']", text: "1"
    find("[data-testid='admin-menu'] summary").click
    assert_selector "[data-testid='approval-badge']", text: "1"
    # ホームの「申請を承認する」とも部分一致するので、管理メニューの中から選ぶ
    within("[data-testid='admin-menu']") { click_on "承認" }

    assert_selector "h1", text: "承認"
    within("[data-testid='approval-row']") do
      assert_text "従業 花子"
      assert_text "打刻修正"
      assert_text @date_label
      click_on "確認する"
    end

    assert_selector "[data-testid='correction-comparison'] tr[data-item='退勤'].is-changed", text: "18:00"
    page.save_screenshot(Rails.root.join("tmp/screenshots/approval-show-1400.png"))

    # 却下はコメントが必須
    accept_confirm { click_on "却下する" }
    assert_text "コメントを入力してください（却下するときは、理由をコメントに書いてください）"
    assert @request.reload.pending?

    fill_in "approval_review[comment]", with: "タイムカードで 18:00 退勤を確認しました。"
    accept_confirm { click_on "承認する" }
    assert_text "従業 花子 さんの #{@date_label} の打刻修正申請を承認しました。勤怠記録を申請内容どおりに更新しました。"
    assert_selector "[data-testid='approvals-empty']", text: "承認待ちの申請はありません"
    assert_no_selector "[data-testid='admin-menu-badge']"

    click_on "処理済み"
    within("[data-testid='approval-row']") do
      assert_text "承認済み"
      assert_text @admin.name
    end
    page.save_screenshot(Rails.root.join("tmp/screenshots/approvals-processed-1400.png"))

    attendance = @employee.attendances.find_by!(work_date: @date)
    assert_equal @date.in_time_zone.change(hour: 18), attendance.clock_out_at
    assert_equal 1, attendance.breaks.count

    click_on "ログアウト"
    log_in_as @employee
    within(".header__nav") { click_on "申請" }
    within("[data-testid='request-row']") do
      assert_text "承認済み"
      assert_text "コメント：タイムカードで 18:00 退勤を確認しました。"
      click_on "詳細"
    end
    assert_selector "[data-testid='review-result']", text: @admin.name
    assert_selector "[data-testid='comparison-base-label']", text: "承認前の記録"
    assert_no_selector "[data-testid='withdraw-button']"
    assert_text "処理済みの申請は取り下げできません"

    visit attendances_path(month: WorkRules.current.period_containing(@date).to_param)
    within("tr[data-date='#{@date.iso8601}']") do
      assert_text "18:00"
      assert_text "8:00"
      assert_no_selector "[data-testid='day-status']", text: "退勤漏れ"
      assert_no_selector "[data-testid='pending-correction']"
    end
  end

  test "スマートフォン幅（375px）でも承認画面の一覧・詳細に横スクロールが出ない" do
    page.current_window.resize_to(375, 812)
    log_in_as @admin
    visit admin_approval_requests_path
    assert_selector "[data-testid='approval-row']"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/approvals-index-375.png"))

    click_on "確認する"
    assert_selector "[data-testid='review-form']"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/approval-show-375.png"))
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "（スプリント9の指摘）375px で「管理」メニューを開いても画面の右にはみ出さず、「承認」の件数が見える" do
    # headless Chrome はウィンドウ幅を 500px 未満にできないことがあるため、表示領域の幅を CDP で 375px に固定する
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    log_in_as @admin
    assert_equal 375, page.evaluate_script("window.innerWidth")
    assert_no_horizontal_scroll

    find("[data-testid='admin-menu'] summary").click
    assert_selector "[data-testid='approval-badge']", text: "1"
    assert_no_horizontal_scroll
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    menu_rect = page.evaluate_script("document.querySelector('.nav__menu-list').getBoundingClientRect().toJSON()")
    badge_rect = page.evaluate_script("document.querySelector(\"[data-testid='approval-badge']\").getBoundingClientRect().toJSON()")
    assert_operator menu_rect["left"], :>=, 0
    assert_operator menu_rect["right"], :<=, client_width
    assert_operator badge_rect["right"], :<=, client_width
    page.save_screenshot(Rails.root.join("tmp/screenshots/admin-menu-375.png"))

    within("[data-testid='admin-menu']") { click_on "承認" }
    assert_selector "h1", text: "承認"
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
