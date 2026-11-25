require "application_system_test_case"

# 有給休暇の残日数（F10）をブラウザで通して確かめる：管理者が付与 → 本人のホーム・休暇に残日数 → 申請 → 承認で減る → 取消で戻る。
# あわせて、スプリント 9.2 の評価の指摘（申請画面のプレビューの範囲外、375px の祝日の「勤務なし」）を確かめる。
class PaidLeavesTest < ApplicationSystemTestCase
  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    # フィクスチャの付与（テスト用の広い期間）を消して、付与の無い状態から始める
    PaidLeaveGrant.where(user: @employee).delete_all
    # 必ず未来の平日（来週の水曜日・木曜日。休日にかかるときはさらに次の週）
    @wednesday = Date.current.next_week(:wednesday)
    @wednesday += 7 while HolidayCalendar.day_off?(@wednesday) || HolidayCalendar.day_off?(@wednesday + 1)
    @thursday = @wednesday + 1
  end

  test "管理者が付与すると、本人のホームと休暇画面に残日数が出て、承認で減り、取消で戻る" do
    log_in_as @admin
    visit admin_employees_path
    within("tr#user_#{@employee.id}") do
      assert_selector "[data-column='paid-leave-balance']", text: "0日"
      # 付与が無い人には「5日未満」の印を付けない（スプリント 16.1）
      assert_no_selector "[data-testid='below-annual-target']"
      assert_selector "[data-testid='no-fiscal-year-grants']", text: "当年度の付与なし"
      click_on "0日"
    end
    assert_selector "h1", text: "従業 花子 さんの有給休暇"
    assert_selector "[data-testid='paid-leave-no-grants']"

    # 付与日を変えると、有効期限が付与日の2年後に合わせて変わる
    granted_on = Date.current - 10
    fill_in "付与日", with: granted_on
    assert_equal (granted_on + 2.years).iso8601, find_field("有効期限").value
    fill_in "日数", with: "1.5"
    click_on "付与する"
    assert_text "従業 花子 さんに有給休暇を 1.5日 付与しました"
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 1.5日"
    page.save_screenshot(Rails.root.join("tmp/screenshots/paid-leave-grants-1400.png"))

    log_out
    log_in_as @employee
    assert_selector "[data-testid='home-paid-leave-balance']", text: "残り 1.5日"
    within(".header__nav") { click_on "休暇" }
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 1.5日"

    # 残日数を超える期間はプレビューで知らせる（送信しても申請できない）
    find(".choice", text: "有給休暇").click
    fill_in "開始日", with: @wednesday
    fill_in "終了日", with: @thursday
    assert_selector "[data-testid='leave-days-preview']", text: "有給休暇の申請できる残り（1.5日）を超えています"
    fill_in "理由", with: "私用のため"
    click_on "申請する"
    assert_selector ".form-errors", text: "有給休暇の残日数が足りないため申請できません（この申請 2日・休暇の日付に使える残り 1.5日）"

    # 1日なら申請できる
    fill_in "終了日", with: @wednesday
    assert_selector "[data-testid='leave-days-preview']", text: "申請後の有給の残り 0.5日"
    click_on "申請する"
    assert_text "を申請しました（承認待ち）"
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 1.5日"
    assert_selector "[data-testid='paid-leave-pending']", text: "1日"
    assert_selector "[data-testid='paid-leave-requestable']", text: "0.5日"
    assert_selector "[data-testid='paid-leave-history-row'][data-kind='pending']"

    log_out
    log_in_as @admin
    leave = @employee.leave_requests.last
    visit admin_approval_request_path(leave)
    assert_selector "[data-testid='leave-paid-balance']", text: "承認されると 0.5日 になります"
    accept_confirm { click_on "承認する" }
    assert_text "有給休暇の残日数から1日引きました。"

    log_out
    log_in_as @employee
    assert_selector "[data-testid='home-paid-leave-balance']", text: "残り 0.5日"
    visit leave_requests_path
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 0.5日"
    within("[data-testid='paid-leave-history-row'][data-kind='usage']") { assert_text "−1日" }
    page.save_screenshot(Rails.root.join("tmp/screenshots/paid-leave-employee-1400.png"))

    log_out
    log_in_as @admin
    visit admin_approval_request_path(leave)
    fill_in "取消の理由", with: "予定が変わったと連絡があったため"
    accept_confirm { click_on "この休暇を取り消す" }
    assert_text "有給休暇の残日数に1日戻しました。"
    visit admin_employee_paid_leave_grants_path(@employee)
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 1.5日"
    assert_selector "[data-testid='paid-leave-history-row'][data-kind='cancelled']", text: "戻し済み"
  end

  test "管理者が理由を入れて付与を削除すると、残日数から消え、付与の画面と本人の休暇画面の履歴に「付与の削除」が出る" do
    PaidLeaveGrant.create!(user: @employee, granted_by: @admin, granted_on: Date.current - 10, days: "10")
    log_in_as @admin
    visit admin_employees_path
    within("tr#user_#{@employee.id}") do
      assert_selector "[data-testid='below-annual-target']", text: "5日未満"
      click_on "10日"
    end
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 10日"
    click_on "削除"

    assert_selector "h1", text: "付与の削除"
    assert_selector "[data-testid='removal-balance-after']", text: "残り 10日 → 残り 0日"
    # 理由の入力欄は必須（空のままではブラウザの入力チェックで送れない）
    assert find_field("削除の理由")[:required]
    fill_in "削除の理由", with: "日数を誤って登録したため"
    accept_confirm { click_on "この付与を削除する" }

    assert_text "を削除しました。削除の記録は、付与・取得の履歴に残ります。"
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 0日"
    within("[data-testid='paid-leave-history-row'][data-kind='removal']") do
      assert_text "付与の削除"
      assert_text "理由：日数を誤って登録したため"
      assert_text "削除：#{@admin.name}"
    end
    scroll_to find("[data-testid='paid-leave-history']")
    page.save_screenshot(Rails.root.join("tmp/screenshots/paid-leave-grant-removed-1400.png"))

    log_out
    log_in_as @employee
    assert_selector "[data-testid='home-paid-leave-balance']", text: "残り 0日"
    visit leave_requests_path
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 0日"
    within("[data-testid='paid-leave-history-row'][data-kind='removal']") do
      assert_text "付与の削除"
      assert_text "理由：日数を誤って登録したため"
    end
  end

  test "申請できる範囲（今日から1年後）より先の日付では、プレビューに日数ではなく範囲の案内を出す" do
    log_in_as @employee
    visit leave_requests_path
    max = Date.current + 1.year
    fill_in "開始日", with: max + 30
    assert_selector "[data-testid='leave-days-preview']", text: "申請できるのは #{(Date.current - 1.year).strftime('%Y/%m/%d')}〜#{max.strftime('%Y/%m/%d')} の日付です"
    assert_no_selector "[data-testid='leave-days-preview']", text: "日数："

    fill_in "開始日", with: @wednesday
    assert_selector "[data-testid='leave-days-preview']", text: "日数：1日"
  end

  test "375px でも残日数・履歴・付与の画面が横にはみ出さず、祝日の勤務なしの行に「勤務なし」が出る" do
    PaidLeaveGrant.create!(user: @employee, granted_by: @admin, granted_on: Date.current - 30, days: "12.5")
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    log_in_as @employee
    assert_selector "[data-testid='home-paid-leave-balance']", text: "残り 12.5日"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/paid-leave-home-375.png"))

    visit leave_requests_path
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 12.5日"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/paid-leave-leaves-375.png"))

    # 祝日（2026/11/3 文化の日、2027/2/11 建国記念の日）の行にも「勤務なし」が出る
    visit attendances_path(month: "2026-11")
    assert_selector "tr[data-date='2026-11-03'] .history-table__empty-label", text: "勤務なし", visible: true
    assert_no_horizontal_scroll
    visit attendances_path(month: "2027-02")
    row = find("tr[data-date='2027-02-11']")
    assert row.has_css?(".history-table__empty-label", text: "勤務なし", visible: true)
    assert_operator row.evaluate_script("this.getBoundingClientRect().height"), :<, 50
    page.save_screenshot(Rails.root.join("tmp/screenshots/history-holiday-empty-375.png"))

    log_out
    log_in_as @admin
    visit admin_employee_paid_leave_grants_path(@employee)
    assert_selector "[data-testid='grant-row']"
    assert_no_horizontal_scroll
    # 付与の削除の確認画面（スプリント 16.1）
    click_on "削除"
    assert_selector "h1", text: "付与の削除"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/paid-leave-grant-removal-375.png"))
    visit admin_employee_paid_leave_grants_path(@employee)
    visit admin_employees_path
    assert_selector "tr#user_#{@employee.id} [data-column='paid-leave-balance']", text: "12.5日"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/employees-paid-leave-375.png"))
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

  def log_out
    click_on "ログアウト"
    assert_text "ログアウトしました。"
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
