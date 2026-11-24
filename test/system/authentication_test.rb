require "application_system_test_case"

class AuthenticationTest < ApplicationSystemTestCase
  test "初期セットアップからログアウト・再ログインまで" do
    User.delete_all

    visit root_path
    assert_selector "h1", text: "初期セットアップ"

    fill_in "氏名", with: "最初 管理者"
    fill_in "メールアドレス", with: "first@example.com"
    fill_in "パスワード", with: "password123", match: :prefer_exact
    fill_in "パスワード（確認）", with: "password123"
    click_on "管理者アカウントを作成"

    assert_text "初期セットアップが完了しました"
    within(".header") do
      assert_text "最初 管理者"
      assert_text "管理者"
      click_on "ログアウト"
    end

    assert_selector "h1", text: "ログイン"
    assert_text "ログアウトしました。"

    fill_in "メールアドレス", with: "first@example.com"
    fill_in "パスワード", with: "wrong-password"
    click_on "ログイン"
    assert_text "メールアドレスまたはパスワードが正しくありません。"

    fill_in "パスワード", with: "password123"
    click_on "ログイン"
    assert_text "ログインしました。"
    assert_selector ".header__user-name", text: "最初 管理者"
  end

  test "スマートフォン幅でもヘッダーとログイン画面が横スクロールなしで表示される" do
    page.current_window.resize_to(375, 800)

    visit login_path
    assert_no_horizontal_scroll

    fill_in "メールアドレス", with: users(:admin).email
    fill_in "パスワード", with: "password123"
    click_on "ログイン"

    within(".header") do
      assert_text "管理 太郎"
      assert_button "ログアウト"
    end
    assert_no_horizontal_scroll
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  private

  def assert_no_horizontal_scroll
    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator scroll_width, :<=, client_width
  end
end
