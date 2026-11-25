require "application_system_test_case"

# 本人のアカウント情報（F2 の追加分・スプリント17）
class AccountTest < ApplicationSystemTestCase
  setup do
    @employee = users(:employee)
    @admin = users(:admin)
  end

  test "歯車からアカウント情報を開き、休暇画面とパスワード変更へ進める" do
    log_in_as @employee
    assert_no_selector "h2", text: "アカウント"

    find("[data-testid='header-settings']").click
    assert_current_path account_path
    assert_selector "h1", text: "従業 花子 さん"
    assert_selector "[data-testid='account-email']", text: "hanako@example.com"
    assert_selector "[data-testid='header-settings'].is-active[aria-current='page']"
    assert_no_selector "main input, main select, main textarea, main button"

    click_on "休暇を申請する・履歴を見る"
    assert_current_path leave_requests_path
    assert_selector "[data-testid='paid-leave-balance']", text: "残り 40日"

    find("[data-testid='header-settings']").click
    click_on "パスワードを変更する"
    assert_current_path edit_password_path
    click_on "← アカウント情報に戻る"
    assert_current_path account_path

    click_on "パスワードを変更する"
    fill_in "現在のパスワード", with: "password123"
    fill_in "新しいパスワード", with: "newpassword1"
    fill_in "新しいパスワード（確認）", with: "newpassword1"
    click_on "変更する"
    assert_text "パスワードを変更しました。"
    assert_current_path account_path
  end

  test "管理者もヘッダーの名前からアカウント情報を開ける" do
    log_in_as @admin
    find("[data-testid='current-user-name']").click
    assert_current_path account_path
    assert_selector "h1", text: "管理 太郎 さん"
    assert_selector "[data-testid='account-role']", text: "管理者"
    click_on "「従業員」画面で変更する"
    assert_current_path edit_admin_employee_path(@admin, from: "account")
    click_on "← アカウント情報に戻る"
    assert_current_path account_path

    click_on "「従業員」画面で変更する"
    click_on "キャンセル"
    assert_current_path account_path

    click_on "「従業員」画面で変更する"
    fill_in "氏名", with: "管理 次郎"
    click_on "更新する"
    assert_current_path account_path
    assert_text "管理 次郎 さんの情報を更新しました。"
    assert_selector "[data-testid='account-name']", text: "管理 次郎"
  end

  test "スマートフォン幅でも、歯車の増えたヘッダーとアカウント情報が横スクロールなしで表示される" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    [ @employee, @admin ].each do |user|
      log_in_as user
      assert_equal 375, page.evaluate_script("window.innerWidth")
      assert_no_horizontal_scroll

      brand = rect(".header__brand")
      bell = rect("[data-testid='notifications-bell']")
      gear = rect("[data-testid='header-settings']")
      name = rect("[data-testid='current-user-name']")
      logout = rect(".header__logout")
      assert_in_delta brand["top"], gear["top"], 12, "歯車はアプリ名と同じ1段目に並ぶ"
      assert_operator bell["right"], :<=, gear["left"], "ベルの右に歯車"
      assert_operator gear["right"], :<=, name["left"], "歯車の右に名前"
      assert_operator logout["right"], :<=, 375
      assert_operator gear["width"], :>=, 32, "押しやすい大きさ"

      find("[data-testid='header-settings']").click
      assert_current_path account_path
      assert_no_horizontal_scroll
      page.save_screenshot(Rails.root.join("tmp/screenshots/account-375-#{user.role}.png"))
      click_on "ログアウト"
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

  def rect(selector)
    page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().toJSON()")
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
