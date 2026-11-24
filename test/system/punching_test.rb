require "application_system_test_case"

class PunchingTest < ApplicationSystemTestCase
  test "ホーム画面で出勤・退勤を打刻する（時計が進み、二重クリックでも1件）" do
    user = users(:employee)
    log_in_as user

    # 時計は秒まで表示され、1秒ごとに進む
    clock = find("[data-testid='current-time'] time")
    assert_match(/\A\d{2}:\d{2}:\d{2}\z/, clock.text)
    first_text = clock.text
    assert_no_text first_text, wait: 3 # 数秒以内に表示が変わる
    assert_selector ".punch__date", text: /\A\d{4}年\d{1,2}月\d{1,2}日\(.\)\z/

    assert_selector "[data-testid='time-clock-status']", text: "未出勤"
    assert_button "退勤", disabled: true

    # 出勤（ダブルクリック）
    find_button("出勤").double_click
    assert_text(/出勤しました（\d{2}:\d{2}）/)
    assert_selector "[data-testid='time-clock-status']", text: "勤務中"
    assert_button "出勤", disabled: true
    assert_equal 1, user.attendances.count
    clock_in_text = user.attendances.sole.clock_in_at.strftime("%H:%M")
    assert_selector "[data-testid='clock-in-time']", text: clock_in_text

    # 再読み込みしても増えない
    visit current_path
    assert_selector "[data-testid='time-clock-status']", text: "勤務中"
    assert_equal 1, user.attendances.count

    # 退勤
    click_on "退勤"
    assert_text(/退勤しました（\d{2}:\d{2}）。本日の実働時間は \d+:\d{2} です。/)
    assert_selector "[data-testid='time-clock-status']", text: "退勤済み"
    assert_button "出勤", disabled: true
    assert_button "退勤", disabled: true
    assert_selector "[data-testid='clock-out-time']", text: user.attendances.sole.clock_out_at.strftime("%H:%M")
    assert_equal 1, user.attendances.count
  end

  test "スマートフォン幅（375px）でも横スクロールなしで打刻できる" do
    page.current_window.resize_to(375, 812)
    log_in_as users(:employee)

    assert_selector "[data-testid='current-time']"
    assert_no_horizontal_scroll
    click_on "出勤"
    assert_text "出勤しました"
    assert_no_horizontal_scroll
    click_on "休憩開始"
    assert_text "休憩を開始しました"
    assert_selector "[data-testid='break-list']"
    assert_no_horizontal_scroll
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "休憩開始・休憩終了を打刻する（休憩中は退勤できず、二重クリックでも1件）" do
    user = users(:employee)
    log_in_as user
    assert_button "休憩開始", disabled: true
    assert_button "休憩終了", disabled: true

    click_on "出勤"
    assert_selector "[data-testid='time-clock-status']", text: "勤務中"

    find_button("休憩開始").double_click
    assert_text(/休憩を開始しました（\d{2}:\d{2}）/)
    assert_selector "[data-testid='time-clock-status']", text: "休憩中"
    assert_button "休憩終了", disabled: false
    assert_button "休憩開始", disabled: true
    assert_button "退勤", disabled: true
    assert_equal 1, AttendanceBreak.count

    find_button("休憩終了").double_click
    assert_text(/休憩を終了しました（\d{2}:\d{2}）。/)
    assert_selector "[data-testid='time-clock-status']", text: "勤務中"
    assert_equal 1, AttendanceBreak.count
    assert_not_nil AttendanceBreak.sole.ended_at

    # 2回目の休憩
    click_on "休憩開始"
    assert_selector "[data-testid='time-clock-status']", text: "休憩中"
    click_on "休憩終了"
    assert_selector "[data-testid='time-clock-status']", text: "勤務中"
    assert_selector "[data-testid='break-list'] li", count: 2
    assert_selector "[data-testid='break-time']", text: "2回"

    click_on "退勤"
    assert_text(/退勤しました（\d{2}:\d{2}）。/)
    assert_selector "[data-testid='time-clock-status']", text: "退勤済み"
    assert_button "休憩開始", disabled: true
    assert_button "休憩終了", disabled: true
    assert_equal 2, user.attendances.sole.breaks.count
  end

  # スプリント3評価の指摘1：「今日の勤務」の実働時間が時計と一緒に進むこと
  test "勤務中の実働時間は画面を開いたまま時計が更新し、休憩中は止まって休憩合計が進む" do
    user = users(:employee)
    attendance = user.attendances.create!(work_date: Date.current, clock_in_at: 2.minutes.ago)
    log_in_as user

    worked = find("[data-testid='worked-time'] [data-clock-target='duration']")
    assert_match(/\A0:0[23]\z/, worked.text)
    # 時計（Stimulus）が更新していることを確かめるため、表示を書き換えてから元に戻ることを見る
    page.execute_script("arguments[0].textContent = '9:99'", worked)
    assert_no_selector "[data-testid='worked-time']", text: "9:99", wait: 3
    assert_match(/\A0:0[23]\z/, worked.text)

    # 休憩中：休憩合計は時計が進め、実働時間は止まる（更新対象にならない）
    attendance.breaks.create!(started_at: 1.minute.ago)
    visit root_path
    assert_selector "[data-testid='time-clock-status']", text: "休憩中"
    assert_no_selector "[data-testid='worked-time'] [data-clock-target='duration']"
    on_break = find("[data-testid='break-time'] [data-clock-target='duration']")
    page.execute_script("arguments[0].textContent = '9:99'", on_break)
    assert_no_selector "[data-testid='break-time']", text: "9:99", wait: 3
    assert_match(/\A0:0[12]\z/, on_break.text)
  end

  # スプリント3評価の指摘3：1280px で打刻カードが中央にあり、カード間に余白がある
  test "1280px では打刻カードが画面の中央にあり、カードどうしが離れている" do
    page.current_window.resize_to(1280, 900)
    log_in_as users(:employee)

    punch = rect_of(".punch")
    today = rect_of("[data-testid='today-attendance']")
    viewport = page.evaluate_script("document.documentElement.clientWidth")
    left_margin = punch["left"]
    right_margin = viewport - punch["right"]
    assert_in_delta left_margin, right_margin, 2, "左右の余白が同じ（中央寄せ）"
    assert_operator today["top"] - punch["bottom"], :>=, 12, "打刻カードと今日の勤務の間に余白がある"
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  private

  def rect_of(selector)
    page.evaluate_script("(function(r){ return { left: r.left, right: r.right, top: r.top, bottom: r.bottom } })(document.querySelector(#{selector.to_json}).getBoundingClientRect())")
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
