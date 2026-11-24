require "application_system_test_case"

class CorrectionRequestsTest < ApplicationSystemTestCase
  setup do
    @user = users(:employee)
    # 2日前の退勤漏れ（出勤から24時間を過ぎているので、ホームからは退勤できない）
    @date = Time.zone.today - 2
    @user.attendances.create!(work_date: @date, clock_in_at: @date.in_time_zone.change(hour: 9))
    @history_path = attendances_path(month: WorkRules.current.period_containing(@date).to_param)
    @date_label = I18n.l(@date, format: :short_with_day)
  end

  test "勤怠履歴から修正申請を出し、申請一覧に承認待ちで出て、履歴に「申請中」が付き、取り下げられる" do
    log_in_as @user
    visit @history_path
    within("tr[data-date='#{@date.iso8601}']") { click_on "修正申請" }

    assert_selector "h1", text: "打刻修正申請"
    assert_selector "[data-testid='current-record']", text: "退勤漏れ"
    assert_field "attendance_correction_request[clock_in_time]", with: "09:00"
    assert_selector "[data-testid='break-row']", count: 1

    # 退勤は翌日 02:00（日付をまたぐ勤務）
    find("select[name='attendance_correction_request[clock_out_day]']").select("翌日 #{I18n.l(@date.tomorrow, format: :short_with_day)}")
    find("input[name='attendance_correction_request[clock_out_time]']").set("02:00")

    # 休憩1は終了が開始より前（エラーになる）、休憩を2つ追加して1つ削除する
    set_break(0, "13:00", "12:00")
    click_on "＋ 休憩を追加"
    assert_selector "[data-testid='break-row']", count: 2
    assert_selector "[data-testid='break-row']:nth-child(2) .break-row__label", text: "休憩2"
    set_break(1, "23:30", "00:15", end_day: "翌日 #{I18n.l(@date.tomorrow, format: :short_with_day)}")
    click_on "＋ 休憩を追加"
    assert_selector "[data-testid='break-row']", count: 3
    within(all("[data-testid='break-row']")[2]) { click_on "削除" }
    assert_selector "[data-testid='break-row']", count: 2
    fill_in "attendance_correction_request[reason]", with: "退勤の打刻を忘れました。翌 2:00 に退勤しています。"
    click_on "申請する"

    assert_text "休憩1の終了時刻は開始時刻より後にしてください"
    assert_selector "[data-testid='break-row'].is-invalid", count: 1
    assert_selector "[data-testid='break-row']", count: 2
    assert_field "attendance_correction_request[clock_out_time]", with: "02:00"
    assert_equal 0, ApprovalRequest.count
    page.save_screenshot(Rails.root.join("tmp/screenshots/correction-form-errors-1400.png"))

    set_break(0, "12:00", "13:00")
    click_on "申請する"

    assert_text "#{@date_label} の打刻修正を申請しました（承認待ち）。承認されるまで勤怠記録は変わりません。"
    assert_selector "[data-testid='request-row'].is-highlighted td[data-column='status']", text: "承認待ち"
    assert_selector "[data-testid='request-row'] td[data-column='summary']", text: "出勤 09:00／退勤 翌 02:00／休憩 2回"
    page.save_screenshot(Rails.root.join("tmp/screenshots/requests-index-1400.png"))
    assert_nil @user.attendances.find_by(work_date: @date).clock_out_at

    # 勤怠履歴には「申請中」の印（記録はまだ変わらない）
    within(".header__nav") { click_on "勤怠履歴" }
    visit @history_path
    assert_selector "tr[data-date='#{@date.iso8601}'] [data-testid='pending-correction']", text: "申請中"
    assert_selector "tr[data-date='#{@date.iso8601}'] [data-testid='day-status']", text: "退勤漏れ"
    find("tr[data-date='#{@date.iso8601}'] [data-testid='pending-correction']").click

    assert_selector "[data-testid='correction-comparison'] tr[data-item='退勤'].is-changed", text: "翌 02:00"
    page.save_screenshot(Rails.root.join("tmp/screenshots/request-show-1400.png"))
    accept_confirm { click_on "この申請を取り下げる" }
    assert_text "#{@date_label} の打刻修正申請を取り下げました。"
    assert_selector "h1 [data-testid='request-status']", text: "取り下げ"
    assert ApprovalRequest.last.withdrawn?
  end

  test "スマートフォン幅（375px）でも横スクロールなしで申請・閲覧できる" do
    page.current_window.resize_to(375, 812)
    log_in_as @user
    visit new_attendance_correction_request_path(date: @date.iso8601)
    assert_selector "h1", text: "打刻修正申請"
    assert_no_horizontal_scroll
    click_on "＋ 休憩を追加"
    assert_selector "[data-testid='break-row']", count: 2
    assert_no_horizontal_scroll
    page.execute_script("document.querySelector('[data-testid=correction-breaks]').scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/screenshots/correction-form-375.png"))

    find("input[name='attendance_correction_request[clock_out_time]']").set("18:00")
    fill_in "attendance_correction_request[reason]", with: "退勤の打刻を忘れました。"
    click_on "申請する"
    assert_text "打刻修正を申請しました"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/requests-index-375.png"))

    click_on "詳細"
    assert_selector "[data-testid='correction-comparison']"
    assert_no_horizontal_scroll
    assert_inside_card "[data-testid='correction-comparison']"
    page.save_screenshot(Rails.root.join("tmp/screenshots/request-show-375.png"))

    visit @history_path
    assert_selector "tr[data-date='#{@date.iso8601}'] [data-testid='pending-correction']", text: "申請中"
    assert_no_horizontal_scroll
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "（スプリント6の指摘）375px で設定画面の「締め日ごとの範囲」がカードからはみ出さない" do
    page.current_window.resize_to(375, 812)
    log_in_as users(:admin)
    visit admin_work_rule_setting_path
    assert_selector "[data-testid='closing-day-periods']"
    assert_no_horizontal_scroll
    assert_inside_card "[data-testid='closing-day-periods'] table"
    page.execute_script("document.querySelector('[data-testid=closing-day-periods]').scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/screenshots/work-rule-settings-periods-375.png"))
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  private

  def set_break(index, start_time, end_time, end_day: nil)
    within(all("[data-testid='break-row']")[index]) do
      find("input[name$='[start_time]']").set(start_time)
      find("select[name$='[end_day]']").select(end_day) if end_day
      find("input[name$='[end_time]']").set(end_time)
    end
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

  # selector の中のすべての要素（文字を含む）の右端が、囲んでいるカードの右端を超えていない
  def assert_inside_card(selector)
    overflow = page.evaluate_script(<<~JS)
      (() => {
        const root = document.querySelector(#{selector.to_json});
        const card = root.closest(".card");
        const limit = card.getBoundingClientRect().right;
        const range = document.createRange();
        let max = 0;
        root.querySelectorAll("*").forEach((element) => {
          max = Math.max(max, element.getBoundingClientRect().right);
          range.selectNodeContents(element);
          max = Math.max(max, range.getBoundingClientRect().right);
        });
        return max - limit;
      })()
    JS
    assert_operator overflow, :<=, 0.5, "#{selector} の中身がカードの右端を #{overflow}px 超えています"
  end
end
