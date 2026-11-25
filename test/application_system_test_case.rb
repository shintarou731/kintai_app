require "test_helper"

# Capybara 3.40 はテスト後のリセット時に CDP の Storage.clearDataForOrigin を origin "*" で呼ぶが、
# 新しい Chrome ではこれが InvalidArgumentError になりテストがエラー扱いになる。
# その場合はクッキーの全削除に切り替える（テスト環境だけの回避策）。
module ChromeStorageResetWorkaround
  private

  def execute_cdp(cmd, params = {})
    super
  rescue Selenium::WebDriver::Error::InvalidArgumentError
    raise unless cmd == "Storage.clearDataForOrigin"

    super("Network.clearBrowserCookies")
  end
end
Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeStorageResetWorkaround)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  private

  # ログイン画面からログインし、移った先に「ログインしました。」が出るまで待つ
  def log_in_as(user, password: "password123")
    visit login_path
    fill_in "メールアドレス", with: user.email
    fill_in "パスワード", with: password
    click_on "ログイン"
    assert_text "ログインしました。"
  end

  # ヘッダーの「ログアウト」を押し、ログイン画面に戻って「ログアウトしました。」が出るまで待つ。
  # ログアウトは button_to の DELETE を Turbo が fetch で送るので、完了を待たずに visit すると送信が打ち切られ、
  # ログインしたまま次の画面を開いてしまうことがある（ログイン画面がホームに移されて、テストが不安定に失敗する）
  def log_out
    within(".header") { click_on "ログアウト" }
    assert_current_path login_path
    assert_text "ログアウトしました。"
  end
end
