require "application_system_test_case"

# ヘッダーの並び（スプリント17の修正）。
# どの幅でも、ナビの各項目・管理メニュー・ベル・歯車・名前・ログアウトが他の要素に重ならず、押せること。
# 押せるかどうかは、要素の中心の座標で document.elementFromPoint を呼び、その要素（か、その中の要素）が返るかで判定する。
class HeaderLayoutTest < ApplicationSystemTestCase
  WIDTHS = [ 320, 375, 601, 640, 768, 820, 880, 920, 1024, 1280 ].freeze
  LONG_NAME = "長谷川長谷川 ジョンジョンジョン".freeze
  # ベルの一覧を確かめる幅。ベルが左に寄る 601〜679px（スプリント17の第2回評価のバグ）と、1段・2段の境目を含める
  BELL_WIDTHS = [ 320, 375, 601, 640, 680, 768, 1024, 1280 ].freeze

  # 押せることを確かめる要素（ナビの各項目と「管理」は .nav__link でまとめて調べる）
  TARGETS = {
    "ナビの項目" => ".header__nav .nav__link",
    "ベル" => "[data-testid='notifications-bell']",
    "歯車" => "[data-testid='header-settings']",
    "名前" => "[data-testid='current-user-name']",
    "ログアウト" => ".header__logout button"
  }.freeze

  setup do
    @employee = users(:employee)
    @admin = users(:admin)
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "従業員：どの幅でもヘッダーの項目が重ならず、すべて押せる" do
    log_in_as @employee
    WIDTHS.each { |width| assert_header_usable(width, admin: false) }
  end

  test "管理者：どの幅でもヘッダーの項目と管理メニューが重ならず、すべて押せる" do
    log_in_as @admin
    WIDTHS.each { |width| assert_header_usable(width, admin: true) }
  end

  test "管理者の名前が長くても、1段と2段の境目の幅でヘッダーの項目が重ならない" do
    @admin.update_columns(name: LONG_NAME)
    log_in_as @admin
    [ 601, 768, 1023, 1024, 1119, 1120, 1280 ].each { |width| assert_header_usable(width, admin: true) }
  end

  test "従業員：どの幅でも、ベルの一覧が画面の内側に収まり、見出しと各通知が読める" do
    notify_twice!(@employee)
    log_in_as @employee
    BELL_WIDTHS.each { |width| assert_notifications_panel_inside(width) }
  end

  test "管理者：どの幅でも、ベルの一覧が画面の内側に収まり、見出しと各通知が読める" do
    notify_twice!(@admin)
    log_in_as @admin
    BELL_WIDTHS.each { |width| assert_notifications_panel_inside(width) }
  end

  test "管理者の名前が長くても、ベルの一覧が画面の内側に収まる" do
    @admin.update_columns(name: LONG_NAME)
    notify_twice!(@admin)
    log_in_as @admin
    (BELL_WIDTHS + [ 679, 1023, 1119 ]).sort.each { |width| assert_notifications_panel_inside(width) }
  end

  test "管理者は iPad の縦向きの幅（768px）でも、歯車と名前からアカウント情報を開ける" do
    log_in_as @admin
    resize_to 768
    visit root_path
    find("[data-testid='header-settings']").click
    assert_current_path account_path

    visit root_path
    find("[data-testid='current-user-name']").click
    assert_current_path account_path

    find("summary", text: "管理").click
    click_on "従業員"
    assert_current_path admin_employees_path
  end

  test "従業員は 640px でも、ナビの「申請」「休暇」を押して移れる" do
    log_in_as @employee
    resize_to 640
    visit root_path
    within(".header__nav") { click_on "申請" }
    assert_current_path approval_requests_path
    within(".header__nav") { click_on "休暇" }
    assert_current_path leave_requests_path
  end

  private

  def assert_header_usable(width, admin:)
    resize_to width
    visit root_path
    assert_equal width, page.evaluate_script("window.innerWidth"), "表示幅が #{width}px に固定されている"

    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator scroll_width, :<=, client_width, "#{width}px：ページ全体に横スクロールが出ない"

    TARGETS.each do |label, selector|
      results = clickable_results(selector)
      assert_not_empty results, "#{width}px：#{label}（#{selector}）がある"
      results.each do |result|
        assert result["ok"], "#{width}px：#{label}「#{result["text"]}」の中心が #{result["hit"]} にふさがれている"
      end
    end

    nav_texts = all(".header__nav .nav__link", visible: true).map { |link| link.text.strip }
    expected = %w[ホーム 勤怠履歴 シフト 申請 休暇]
    expected += [ "管理" ] if admin
    assert_equal expected, nav_texts.map { |text| text.sub(/\s*\d+\z/, "") }, "#{width}px：ナビの項目がすべて見えている"

    assert_admin_menu_usable(width) if admin
  end

  # 管理メニューを開き、一覧が画面からはみ出さず、各項目が他の要素に隠れていないこと
  def assert_admin_menu_usable(width)
    find("summary", text: "管理").click
    assert_selector ".nav__menu-list", visible: true

    list = page.evaluate_script("document.querySelector('.nav__menu-list').getBoundingClientRect().toJSON()")
    assert_operator list["left"], :>=, 0, "#{width}px：管理メニューの一覧が左にはみ出さない"
    assert_operator list["right"], :<=, width, "#{width}px：管理メニューの一覧が右にはみ出さない"
    assert_operator list["bottom"], :<=, page.evaluate_script("window.innerHeight"), "#{width}px：管理メニューの一覧が下で切れない"

    results = clickable_results(".nav__menu-list .nav__menu-item")
    assert_equal 7, results.size
    results.each do |result|
      assert result["ok"], "#{width}px：管理メニューの「#{result["text"]}」の中心が #{result["hit"]} にふさがれている"
    end

    find("summary", text: "管理").click
    assert_no_selector ".nav__menu-list", visible: true
  end

  # ベルを押して一覧を開き、一覧・見出し・各通知の矩形が 0〜innerWidth（下は innerHeight）の内側にあること。
  # 見出しは、中心の座標で elementFromPoint を呼んで、他の要素に隠れていないことも確かめる
  def assert_notifications_panel_inside(width)
    resize_to width
    visit root_path
    assert_equal width, page.evaluate_script("window.innerWidth"), "表示幅が #{width}px に固定されている"

    find("[data-testid='notifications-bell']").click
    assert_selector "[data-testid='notifications-panel']", visible: true
    assert_selector ".notifications-menu__title", text: "通知", visible: true

    rects = page.evaluate_script(<<~JS)
      (() => {
        const rect = (el) => el.getBoundingClientRect().toJSON();
        const title = document.querySelector(".notifications-menu__title");
        const t = title.getBoundingClientRect();
        const hit = document.elementFromPoint(t.left + t.width / 2, t.top + t.height / 2);
        return {
          panel: rect(document.querySelector("[data-testid='notifications-panel']")),
          title: rect(title),
          titleVisible: !!hit && (hit === title || title.contains(hit)),
          items: Array.from(document.querySelectorAll("[data-testid='notifications-panel'] .notification-item")).map(rect),
          height: window.innerHeight
        };
      })()
    JS

    { "一覧" => rects["panel"], "見出し" => rects["title"] }.each do |label, rect|
      assert_operator rect["left"], :>=, 0, "#{width}px：ベルの#{label}が左にはみ出さない（left=#{rect["left"]}）"
      assert_operator rect["right"], :<=, width, "#{width}px：ベルの#{label}が右にはみ出さない（right=#{rect["right"]}）"
    end
    assert_operator rects["panel"]["bottom"], :<=, rects["height"], "#{width}px：ベルの一覧が下で切れない"
    assert rects["titleVisible"], "#{width}px：ベルの一覧の見出しが他の要素に隠れていない"
    rects["items"].each_with_index do |rect, index|
      assert_operator rect["left"], :>=, rects["panel"]["left"], "#{width}px：#{index + 1}件目の通知の左端が一覧の中にある"
      assert_operator rect["right"], :<=, rects["panel"]["right"], "#{width}px：#{index + 1}件目の通知の右端が一覧の中にある"
    end

    find("[data-testid='notifications-bell']").click
    assert_no_selector "[data-testid='notifications-panel']", visible: true
  end

  # selector に合う各要素について、中心の座標の elementFromPoint がその要素自身（か、その子孫）かを返す
  def clickable_results(selector)
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(#{selector.to_json})).map((el) => {
        const r = el.getBoundingClientRect();
        const x = r.left + r.width / 2;
        const y = r.top + r.height / 2;
        const hit = document.elementFromPoint(x, y);
        const describe = (node) => node ? `${node.tagName.toLowerCase()}.${Array.from(node.classList).join(".")}` : "（画面の外）";
        return {
          text: el.textContent.trim().replace(/\\s+/g, " "),
          ok: r.width > 0 && r.height > 0 && !!hit && (hit === el || el.contains(hit)),
          hit: describe(hit)
        };
      })
    JS
  end

  # ベルの一覧に通知が並ぶようにする（1件は長い件名で、折り返しも確かめる）
  def notify_twice!(user)
    Notification.create!(recipient: user, kind: "shift_published", title: "12月のシフトが公開されました", body: "本文", path: "/shifts")
    Notification.create!(recipient: user, kind: "shift_published",
                         title: "長い件名の通知：#{"シフトの変更があります。" * 4}", body: "本文#{"とても長い本文です。" * 6}", path: "/shifts")
  end

  def resize_to(width)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
  end

  def log_in_as(user)
    visit login_path
    fill_in "メールアドレス", with: user.email
    fill_in "パスワード", with: "password123"
    click_on "ログイン"
    assert_text "ログインしました。"
  end
end
