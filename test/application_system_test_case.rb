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
end
