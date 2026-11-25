require "application_system_test_case"

class EmployeeManagementTest < ApplicationSystemTestCase
  test "管理者が従業員を追加・編集・無効化し、従業員のログインと画面の出し分けを確認する" do
    log_in_as users(:admin)

    # 管理メニューから従業員一覧へ
    within(".header") do
      find("summary", text: "管理").click
      click_on "従業員"
    end
    assert_selector "h1", text: "従業員"
    assert_selector "[data-testid='employees-table']", text: "従業 花子"

    # 追加（最初は重複メールでエラー）
    click_on "＋ 従業員を追加"
    fill_in "氏名", with: "新人 三郎"
    fill_in "メールアドレス", with: "hanako@example.com"
    fill_in "初期パスワード", with: "initial123"
    fill_in "入社日", with: Date.new(2026, 11, 1)
    select "パート・アルバイト", from: "雇用区分"
    click_on "登録する"
    assert_text "メールアドレスはすでに登録されています"

    fill_in "メールアドレス", with: "saburo@example.com"
    fill_in "初期パスワード", with: "initial123"
    click_on "登録する"
    assert_text "新人 三郎 さんを登録しました"
    within(:xpath, "//tr[td[contains(., '新人 三郎')]]") do
      assert_text "saburo@example.com"
      assert_text "従業員"
      assert_text "パート・アルバイト"
      assert_text "有効"
    end

    # 無効化（確認ダイアログを承認）
    within(:xpath, "//tr[td[contains(., '新人 三郎')]]") { click_on "編集" }
    accept_confirm { click_on "無効にする" }
    assert_text "新人 三郎 さんを無効にしました"
    assert_button "有効に戻す"

    # 無効な従業員はログインできない
    log_out
    log_in_with "saburo@example.com", "initial123"
    assert_text "このアカウントは無効になっているため、ログインできません"

    # 有効に戻す
    log_in_as users(:admin)
    visit edit_admin_employee_path(User.find_by!(email: "saburo@example.com"))
    click_on "有効に戻す"
    assert_text "新人 三郎 さんを有効にしました"
    log_out

    # 従業員としてログイン：管理メニューは出ず、管理画面は拒否される
    log_in_with "saburo@example.com", "initial123"
    assert_text "ログインしました。"
    assert_no_selector "summary", text: "管理"
    visit admin_employees_path
    assert_current_path root_path
    assert_text "この画面を表示する権限がありません。"

    # 自分のパスワードを変更する
    click_on "新人 三郎"
    fill_in "現在のパスワード", with: "initial123"
    fill_in "新しいパスワード", with: "mypassword1"
    fill_in "新しいパスワード（確認）", with: "mypassword1"
    click_on "変更する"
    assert_text "パスワードを変更しました。"
  end

  test "スマートフォン幅でも従業員一覧とヘッダーが横スクロールなしで表示される" do
    page.current_window.resize_to(375, 800)
    log_in_as users(:admin)

    visit admin_employees_path
    assert_selector "h1", text: "従業員"
    assert_text "hanako@example.com"
    within(".header") { assert_selector "summary", text: "管理" }
    assert_no_horizontal_scroll

    visit new_admin_employee_path
    assert_no_horizontal_scroll
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  private

  # ログインに失敗する場合も確かめるため、結果のメッセージは呼び出し側で確かめる
  def log_in_with(email, password)
    visit login_path
    fill_in "メールアドレス", with: email
    fill_in "パスワード", with: password
    click_on "ログイン"
  end

  def assert_no_horizontal_scroll
    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator scroll_width, :<=, client_width
  end
end
