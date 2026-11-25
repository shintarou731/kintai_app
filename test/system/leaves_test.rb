require "application_system_test_case"

class LeavesTest < ApplicationSystemTestCase
  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    # 必ず未来の平日（来週の水曜日・木曜日。祝日にかかるときはさらに次の週）
    @wednesday = Date.current.next_week(:wednesday)
    @wednesday += 7 while HolidayCalendar.day_off?(@wednesday) || HolidayCalendar.day_off?(@wednesday + 1)
    @thursday = @wednesday + 1
    @history_month = WorkRules.current.period_containing(@wednesday).to_param
  end

  test "従業員が半休を申請し、管理者が承認すると、勤怠履歴の該当日に「有給（午前半休）」と表示される" do
    log_in_as @employee
    within(".header__nav") { click_on "休暇" }
    assert_selector "h1", text: "休暇"

    find(".choice", text: "有給休暇").click
    find(".choice", text: "午前半休").click
    fill_in "開始日", with: @wednesday
    # 半休は1日だけ：終了日は開始日に合わせて固定される
    assert_equal @wednesday.iso8601, find_field("終了日").value
    assert find_field("終了日").readonly?
    assert_selector "[data-testid='leave-days-preview']", text: "日数：0.5日"
    fill_in "理由", with: "通院のため午前中お休みします。"
    click_on "申請する"

    assert_text "の有給休暇（午前半休）を申請しました（承認待ち）"
    within("[data-testid='leave-row'].is-highlighted") do
      assert_text "午前半休"
      assert_text "0.5日"
      assert_text "承認待ち"
    end
    page.save_screenshot(Rails.root.join("tmp/screenshots/leaves-index-1400.png"))

    visit attendances_path(month: @history_month)
    within("tr[data-date='#{@wednesday.iso8601}']") { assert_selector "[data-testid='day-leave']", text: "有給（午前半休）・申請中" }

    click_on "ログアウト"
    log_in_as @admin
    assert_selector "[data-testid='admin-menu-badge']", text: "1"
    visit admin_approval_requests_path
    within("[data-testid='approval-row']") do
      assert_text "休暇"
      assert_text "有給休暇・午前半休（0.5日）"
      click_on "確認する"
    end
    assert_selector "[data-testid='leave-details']", text: "午前半休"
    page.save_screenshot(Rails.root.join("tmp/screenshots/leave-approval-1400.png"))
    accept_confirm { click_on "承認する" }
    assert_text "の休暇申請を承認しました。勤怠履歴の該当日に「有給（午前半休）」と表示されます。"

    click_on "ログアウト"
    log_in_as @employee
    visit attendances_path(month: @history_month)
    within("tr[data-date='#{@wednesday.iso8601}']") do
      assert_selector "[data-testid='day-leave'][data-leave-status='approved']", text: "有給（午前半休）"
    end
    assert_selector "[data-testid='leave-totals']", text: "有給 0.5日"
    page.save_screenshot(Rails.root.join("tmp/screenshots/history-with-leave-1400.png"))
  end

  test "入力の誤り（重なる期間）は画面上部とフォームに出て、入力した内容が残る" do
    approved = @employee.leave_requests.new(target_date: @wednesday, end_date: @thursday, leave_type: "paid", reason: "旅行")
    assert approved.submit
    approved.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: Time.current)

    log_in_as @employee
    visit leave_requests_path
    find(".choice", text: "特別休暇").click
    fill_in "開始日", with: @thursday
    fill_in "終了日", with: @thursday + 1
    fill_in "理由", with: "慶弔のため"
    click_on "申請する"

    assert_selector ".flash--alert", text: "休暇を申請できませんでした。入力内容を確認してください。"
    assert_selector ".form-errors", text: "（承認済み）と期間が重なっています"
    assert_field "理由", with: "慶弔のため"
    assert find("input[name='leave_request[leave_type]'][value='special']", visible: :all).checked?
  end

  test "未来の承認済みの休暇に取消申請を出し、管理者が承認すると勤怠履歴から消える" do
    leave = @employee.leave_requests.new(target_date: @wednesday, end_date: @thursday, leave_type: "paid", reason: "旅行")
    assert leave.submit
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: Time.current)

    log_in_as @employee
    visit leave_requests_path
    within("[data-testid='leave-row']") { click_on "詳細" }
    fill_in "取消の理由", with: "予定が変わり、出勤できるようになったため。"
    accept_confirm { click_on "取消を申請する" }
    assert_text "の取消を申請しました（承認待ち）。承認されるまで休暇は有効です。"
    assert_selector "h1", text: "休暇取消申請"

    visit attendances_path(month: @history_month)
    within("tr[data-date='#{@wednesday.iso8601}']") { assert_selector "[data-testid='day-leave']", text: "有給（全日）・取消申請中" }

    click_on "ログアウト"
    log_in_as @admin
    visit admin_approval_requests_path
    within("[data-testid='approval-row']") do
      assert_text "休暇取消"
      click_on "確認する"
    end
    accept_confirm { click_on "承認する" }
    assert_text "の休暇取消申請を承認しました。休暇を取り消しました"

    click_on "ログアウト"
    log_in_as @employee
    visit attendances_path(month: @history_month)
    within("tr[data-date='#{@wednesday.iso8601}']") { assert_no_selector "[data-testid='day-leave']" }
    # 取消済みの休暇は「これからの休暇」には出ず、「すべて」に出る
    visit leave_requests_path
    assert_selector "[data-testid='leaves-empty']", text: "これからの休暇はありません。"
    visit leave_requests_path(status: "all")
    within("[data-testid='leave-row']") { assert_selector "[data-testid='leave-cancelled']", text: "取消済み" }
  end

  test "日数の表示は祝日も除き、祝日の名前を示す。祝日だけの有給休暇は申請できない" do
    today = Date.current
    holiday, name = HolidayCalendar.holidays_between(today + 1, today + 300).find { |date, _name| !date.on_weekend? }
    log_in_as @employee
    visit leave_requests_path

    find(".choice", text: "有給休暇").click
    fill_in "開始日", with: holiday
    fill_in "終了日", with: holiday
    assert_selector "[data-testid='leave-days-preview']",
                    text: "日数：0日（土日・祝日を除く）・期間 1日間・祝日：#{holiday.month}/#{holiday.day} #{name}"
    fill_in "理由", with: "祝日だけの有給休暇"
    click_on "申請する"
    assert_selector ".form-errors", text: "休日だけの期間は申請できません"

    # 前日（平日なら）〜祝日の2日間にすると、休日を除いた日数が出る
    fill_in "開始日", with: holiday - 1
    fill_in "終了日", with: holiday
    expected = HolidayCalendar.working_day?(holiday - 1) ? "日数：1日（土日・祝日を除く）・期間 2日間" : "期間 2日間"
    assert_selector "[data-testid='leave-days-preview']", text: expected
  end

  test "（スプリント9の指摘）1日だけの入力で開始日を過去に変えると、終了日も一緒に動く。複数日にした後は終了日を保つ" do
    today = Date.current
    log_in_as @employee
    visit leave_requests_path
    assert_equal today.iso8601, find_field("終了日").value

    fill_in "開始日", with: today - 5
    assert_equal (today - 5).iso8601, find_field("終了日").value
    assert_selector "[data-testid='leave-days-preview']", text: "期間 1日間"

    # 終了日を自分で変えて複数日にした後は、開始日を変えても終了日はそのまま（開始日より前にならない限り）
    fill_in "終了日", with: today - 1
    fill_in "開始日", with: today - 3
    assert_equal (today - 1).iso8601, find_field("終了日").value
    assert_selector "[data-testid='leave-days-preview']", text: "期間 3日間"
  end

  test "スマートフォン幅（375px）でも休暇画面・休暇の詳細・休暇のある勤怠履歴に横スクロールが出ない" do
    leave = @employee.leave_requests.new(target_date: @wednesday, end_date: @thursday, leave_type: "paid", reason: "旅行")
    assert leave.submit
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: Time.current)

    page.current_window.resize_to(375, 812)
    log_in_as @employee
    visit leave_requests_path
    assert_selector "[data-testid='leave-form']"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/leaves-index-375.png"))

    within("[data-testid='leave-row']") { click_on "詳細" }
    assert_selector "[data-testid='cancellation-form']"
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/leave-show-375.png"))

    visit attendances_path(month: @history_month)
    within("tr[data-date='#{@wednesday.iso8601}']") { assert_selector "[data-testid='day-leave']", text: "有給（全日）" }
    assert_no_horizontal_scroll
    page.save_screenshot(Rails.root.join("tmp/screenshots/history-with-leave-375.png"))
  ensure
    page.current_window.resize_to(1400, 1400)
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
