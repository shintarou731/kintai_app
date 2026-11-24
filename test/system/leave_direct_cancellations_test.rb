require "application_system_test_case"

# 管理者による承認済み休暇の直接取消（F9 の追加分）を、画面の操作で確かめる
class LeaveDirectCancellationsTest < ApplicationSystemTestCase
  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    @today = Date.current
    # 必ず未来の平日（来週の水曜日。祝日ならさらに次の週）
    @wednesday = Date.current.next_week(:wednesday)
    @wednesday += 7 while HolidayCalendar.day_off?(@wednesday)
  end

  test "当日の承認済み休暇：従業員には「管理者に依頼」と出て、管理者が理由を入れて取り消すと、勤怠履歴から消える" do
    leave = approved_leave!(from: @today, to: @today)

    log_in_as @employee
    visit approval_request_path(leave)
    assert_selector "[data-testid='cancellation-unavailable']", text: "取消は管理者に依頼してください"
    assert_no_selector "[data-testid='cancellation-form']"
    visit attendances_path(month: WorkRules.current.period_containing(@today).to_param)
    within("tr[data-date='#{@today.iso8601}']") { assert_selector "[data-testid='day-leave']", text: "有給（全日）" }

    log_out
    log_in_as @admin
    visit admin_approval_requests_path(status: "processed")
    within("##{ActionView::RecordIdentifier.dom_id(leave)}") { click_on "詳細" }
    within("[data-testid='direct-cancellation-section']") do
      assert_text "開始日が今日・過去・未来のどれでも、ここから直接取り消せます"
      fill_in "取消の理由", with: "本人から、体調が戻り出勤したと連絡があったため。"
      accept_confirm(/従業 花子 さんの .* の有給休暇（全日）を取り消しますか？/) { click_on "この休暇を取り消す" }
    end
    assert_text "従業 花子 さんの #{I18n.l(@today, format: :short_with_day)} の有給休暇（全日）を取り消しました。"
    within("[data-testid='leave-details']") do
      assert_selector "[data-testid='leave-cancelled-by']", text: "管理 太郎"
      assert_selector "[data-testid='leave-cancellation-reason']", text: "本人から、体調が戻り出勤したと連絡があったため。"
    end
    page.save_screenshot(Rails.root.join("tmp/screenshots/leave-direct-cancel-done-1400.png"))

    visit admin_approval_requests_path(status: "processed")
    within("##{ActionView::RecordIdentifier.dom_id(leave)}") do
      assert_selector "[data-testid='leave-cancelled']", text: "取消済み"
      assert_selector "[data-testid='direct-cancellation-by']", text: "取消：管理 太郎"
    end

    log_out
    log_in_as @employee
    visit attendances_path(month: WorkRules.current.period_containing(@today).to_param)
    within("tr[data-date='#{@today.iso8601}']") { assert_no_selector "[data-testid='day-leave']" }
  end

  test "承認待ちの取消申請がある休暇を直接取り消すと、取消申請が承認待ちの一覧から消える（375px でも操作できる）" do
    leave = approved_leave!(from: @wednesday, to: @wednesday)
    request = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "予定が変わったため")
    assert request.submit

    # headless Chrome はウィンドウ幅を 500px 未満にできないことがあるため、表示領域の幅を CDP で 375px に固定する
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    log_in_as @admin
    assert_equal 375, page.evaluate_script("window.innerWidth")
    visit admin_approval_request_path(leave)
    assert_selector "[data-testid='direct-cancellation-pending-request']", text: "この休暇には承認待ちの取消申請があります"
    assert_no_horizontal_scroll
    page.scroll_to(find("[data-testid='direct-cancellation-section']"))
    page.save_screenshot(Rails.root.join("tmp/screenshots/leave-direct-cancel-375.png"))

    fill_in "取消の理由", with: "取消申請の内容を確認し、直接取り消しました。"
    accept_confirm { click_on "この休暇を取り消す" }
    assert_text "承認待ちだった取消申請も、処理済みにしました。"
    assert_no_horizontal_scroll

    visit admin_approval_requests_path
    assert_no_selector "##{ActionView::RecordIdentifier.dom_id(request)}"
    visit admin_approval_requests_path(status: "processed")
    within("##{ActionView::RecordIdentifier.dom_id(request)}") do
      assert_selector "[data-testid='closed-by-direct-cancellation']", text: "直接取消で処理済み"
    end

    # （スプリント9.1の指摘）375px の処理済み一覧で、直接取消の行の「結果」欄は、バッジが横に並び、その下に理由が全幅で出る
    leave_row = "##{ActionView::RecordIdentifier.dom_id(leave)}"
    approved_badge = rect_of("#{leave_row} td[data-column=status] [data-testid='request-status']")
    cancelled_badge = rect_of("#{leave_row} td[data-column=status] [data-testid='leave-cancelled']")
    reason = rect_of("#{leave_row} [data-testid='direct-cancellation-reason']")
    assert_in_delta approved_badge["top"], cancelled_badge["top"], 2, "バッジ2つは同じ行に並ぶ"
    assert_operator approved_badge["height"], :<, 30, "バッジが縦に引き伸ばされない"
    assert_operator reason["top"], :>=, approved_badge["bottom"], "取消の理由はバッジの下に出る"
    cell = rect_of("#{leave_row} td[data-column=status] .approvals-table__cell")
    assert_in_delta cell["width"], reason["width"], 1, "取消の理由は値の欄の幅いっぱいに出る（細い列にならない）"
    assert_operator reason["width"], :>, 150
    assert_no_horizontal_scroll
    page.execute_script("document.querySelector(#{leave_row.to_json}).scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/screenshots/approvals-processed-direct-cancel-375.png"))
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

  def approved_leave!(from:, to:)
    leave = @employee.leave_requests.new(target_date: from, end_date: to, leave_type: "paid", day_part: "full_day", reason: "私用のため")
    assert leave.submit, leave.errors.full_messages.inspect
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: Time.current)
    leave
  end

  def log_in_as(user)
    visit login_path
    fill_in "メールアドレス", with: user.email
    fill_in "パスワード", with: "password123"
    click_on "ログイン"
    assert_text "ログインしました。"
  end

  # ログアウトが終わってログイン画面が出るまで待つ（次の visit と競合しないように）
  def log_out
    click_on "ログアウト"
    assert_field "メールアドレス"
  end

  def rect_of(selector)
    page.evaluate_script("(() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect(); "                          "return { top: r.top, bottom: r.bottom, width: r.width, height: r.height }; })()")
  end

  def assert_no_horizontal_scroll
    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator scroll_width, :<=, client_width
  end
end
