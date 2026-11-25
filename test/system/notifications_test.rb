require "application_system_test_case"

# アプリ内通知（F16）：ヘッダーのベル → 一覧 → 通知を押すと関連する画面へ移って既読になる・すべて既読にする・375px のヘッダー
class NotificationsTest < ApplicationSystemTestCase
  setup do
    @admin = users(:admin)
    @employee = users(:employee)
  end

  # 花子の打刻修正申請を管理者が承認した（花子に「承認」、管理者に「新しい申請」の通知が届く）
  def approved_correction!
    request = @employee.attendance_correction_requests.new(target_date: Date.current - 3, clock_in_time: "09:00", clock_out_time: "18:00",
                                                           reason: "打刻を忘れたため")
    assert request.submit
    review = ApprovalReview.new(approval_request: request, reviewer: @admin, decision: "approve", comment: "確認しました")
    assert review.save
    request
  end

  def assert_no_horizontal_scroll
    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator scroll_width, :<=, client_width
  end

  test "ベルの未読の件数を押すと一覧が開き、通知を押すと申請の詳細へ移って既読になる" do
    request = approved_correction!
    log_in_as @employee
    assert_selector "[data-testid='notifications-badge']", text: "1"

    find("[data-testid='notifications-bell']").click
    within("[data-testid='notifications-panel']") do
      assert_text "打刻修正の申請が承認されました"
      assert_text "コメント：確認しました"
      page.save_screenshot(Rails.root.join("tmp/screenshots/notifications-menu-1400.png"))
      find("[data-testid='notification-item']", text: "打刻修正の申請が承認されました").click
    end

    assert_current_path approval_request_path(request)
    assert_no_selector "[data-testid='notifications-badge']"
    find("[data-testid='notifications-bell']").click
    assert_selector "[data-testid='notifications-panel'] [data-testid='notification-item'][data-state='read']"
  end

  test "通知の一覧で「すべて既読にする」と、未読が無くなる。管理者には新しい申請の通知が届いている" do
    approved_correction!
    Notifier.paid_leave_granted(PaidLeaveGrant.create!(user: @employee, granted_on: Date.current, days: "10", granted_by: @admin))
    log_in_as @employee
    assert_selector "[data-testid='notifications-badge']", text: "2"

    find("[data-testid='notifications-bell']").click
    click_on "すべての通知を見る"
    assert_selector "h1", text: "通知"
    titles = all("[data-testid='notifications-list'] [data-testid='notification-title']").map(&:text)
    assert_equal [ "有給休暇が10日付与されました", "打刻修正の申請が承認されました（#{I18n.l(Date.current - 3, format: :short_with_day)}）" ], titles
    click_on "すべて既読にする"
    assert_text "2件の通知を既読にしました。"
    assert_no_selector "[data-testid='notifications-badge']"
    assert_no_selector "[data-testid='notifications-list'] [data-testid='notification-item'][data-state='unread']"

    log_out
    log_in_as @admin
    assert_selector "[data-testid='notifications-badge']", text: "1"
    find("[data-testid='notifications-bell']").click
    find("[data-testid='notification-item']", text: "従業 花子 さんから打刻修正の申請が届きました").click
    assert_selector "h1", text: "打刻修正申請"
    assert_current_path %r{\A/admin/approvals/\d+\z}
  end

  test "375px でも、ベルとバッジがヘッダーに収まり、開いた一覧も画面の中に収まる" do
    approved_correction!
    # 従業員はバッジが最も長い「99+」になる場合で確かめる
    now = Time.current
    Notification.insert_all!(Array.new(100) do |index|
      { recipient_id: @employee.id, kind: "shift_published", title: "シフトが公開されました（#{index}）", created_at: now - index.hours, updated_at: now }
    end)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    [ @employee, @admin ].each do |user|
      log_in_as user
      assert_equal 375, page.evaluate_script("window.innerWidth")
      assert_selector "[data-testid='notifications-badge']"
      assert_no_horizontal_scroll
      header = page.evaluate_script("document.querySelector('.header__user').getBoundingClientRect().toJSON()")
      bell = page.evaluate_script("document.querySelector(\"[data-testid='notifications-bell']\").getBoundingClientRect().toJSON()")
      badge = page.evaluate_script("document.querySelector(\"[data-testid='notifications-badge']\").getBoundingClientRect().toJSON()")
      assert_operator header["right"], :<=, 375
      assert_operator badge["right"], :<=, 375
      name = page.evaluate_script("document.querySelector(\"[data-testid='current-user-name']\").getBoundingClientRect().toJSON()")
      assert_operator badge["right"], :<=, name["left"], "バッジがユーザー名にかからない"
      brand = page.evaluate_script("document.querySelector('.header__brand').getBoundingClientRect().toJSON()")
      assert_in_delta brand["top"], bell["top"], 12, "ベルはアプリ名と同じ1段目に並ぶ"

      find("[data-testid='notifications-bell']").click
      panel = page.evaluate_script("document.querySelector(\"[data-testid='notifications-panel']\").getBoundingClientRect().toJSON()")
      assert_operator panel["left"], :>=, 0
      assert_operator panel["right"], :<=, 375
      assert_no_horizontal_scroll
      page.save_screenshot(Rails.root.join("tmp/screenshots/notifications-menu-375-#{user.role}.png"))

      visit notifications_path
      assert_no_horizontal_scroll
      page.save_screenshot(Rails.root.join("tmp/screenshots/notifications-index-375-#{user.role}.png"))
      log_out
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
