require "test_helper"

# アプリ内通知（F16）の画面：ヘッダーのベル・一覧（新しい順・発生日時・ページ分け・未読の絞り込み）・
# 通知を開くと既読になって関連する画面へ移る・すべて既読にする・他の人の通知は読めない／既読にできない
class NotificationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 25, 18, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
  end

  teardown { travel_back }

  def notify!(user, title: "お知らせ", path: "/shifts?month=2026-11", at: NOW - 1.hour, kind: "shift_published", read_at: nil)
    Notification.create!(recipient: user, kind: kind, title: title, body: "本文", path: path, created_at: at, read_at: read_at)
  end

  test "ログインしていなければ、一覧も既読もログイン画面へ" do
    note = notify!(@employee)
    get notifications_path
    assert_redirected_to login_path
    post notification_reading_path(note)
    assert_redirected_to login_path
    assert note.reload.unread?
  end

  test "ヘッダーにベルと未読の件数のバッジがあり、ベルの一覧に新しい通知が出る（未読が無ければバッジは出ない）" do
    sign_in_as @employee
    get root_path
    assert_select "[data-testid='notifications-bell']"
    assert_select "[data-testid='notifications-badge']", 0
    assert_select "[data-testid='notifications-panel']", text: /通知はまだありません/

    notify!(@employee, title: "古い通知", at: NOW - 2.days)
    notify!(@employee, title: "新しい通知", at: NOW - 5.minutes)
    notify!(@employee, title: "既読の通知", at: NOW - 1.day, read_at: NOW - 1.hour)
    notify!(@admin, title: "管理者あての通知")
    get root_path
    assert_select "[data-testid='notifications-badge']", text: "2"
    assert_select "[data-testid='notifications-bell'][aria-label=?]", "通知（未読 2件）"
    assert_select "[data-testid='notifications-menu-list'] [data-testid='notification-title']" do |titles|
      assert_equal [ "新しい通知", "既読の通知", "古い通知" ], titles.map { |node| node.text.strip }
    end
    assert_select "[data-testid='notifications-menu-list']", text: /管理者あての通知/, count: 0
    assert_select "a[data-testid='notifications-menu-all'][href=?]", notifications_path
    assert_select "[data-testid='notifications-menu-read-all']"
  end

  test "バッジは 100件以上で「99+」になり、ベルの一覧は新しい6件まで" do
    rows = Array.new(100) do |index|
      { recipient_id: @employee.id, kind: "shift_published", title: "通知#{index}", created_at: NOW - index.minutes, updated_at: NOW }
    end
    Notification.insert_all!(rows)
    sign_in_as @employee
    get root_path
    assert_select "[data-testid='notifications-badge']", text: "99+"
    assert_select "[data-testid='notifications-menu-list'] [data-testid='notification-item']", Notification::MENU_LIMIT
  end

  test "一覧は自分の通知だけを新しい順に出し、発生日時と未読の印を出す" do
    notify!(@employee, title: "3日前", at: NOW - 3.days, read_at: NOW - 1.day)
    notify!(@employee, title: "5分前", at: NOW - 5.minutes)
    notify!(@employee, title: "去年", at: Time.zone.local(2025, 12, 31, 9, 5))
    notify!(@admin, title: "他の人の通知")
    sign_in_as @employee

    get notifications_path
    assert_response :success
    assert_select "[data-testid='notifications-list'] [data-testid='notification-item']" do |items|
      assert_equal %w[unread read unread], items.map { |item| item["data-state"] }
    end
    assert_select "[data-testid='notifications-list'] [data-testid='notification-title']" do |titles|
      assert_equal [ "5分前", "3日前", "去年" ], titles.map { |node| node.text.strip }
    end
    assert_select "[data-testid='notifications-list'] [data-testid='notification-time']" do |times|
      texts = times.map { |node| node.text.squish }
      assert_equal "11/25(水) 17:55（5分前）", texts[0]
      assert_equal "11/22(日) 18:00（3日前）", texts[1]
      assert_equal "2025年12月31日(水) 09:05", texts[2]
    end
    assert_select "[data-testid='notifications-list'] [data-testid='notification-unread']", 2
    assert_not_includes response.body, "他の人の通知"
    assert_select "[data-testid='notifications-filter-unread'] .tabs__count", text: "2"
  end

  test "未読だけに絞り込める" do
    notify!(@employee, title: "未読の通知")
    notify!(@employee, title: "既読の通知", read_at: NOW - 1.minute)
    sign_in_as @employee
    get notifications_path(filter: "unread")
    assert_select "[data-testid='notification-title']", text: "未読の通知"
    assert_select "[data-testid='notifications-list'] [data-testid='notification-title']", text: "既読の通知", count: 0
  end

  test "1ページ20件ずつに分け、前後のページへ移れる。範囲外や不正なページは近いページにする" do
    rows = Array.new(45) do |index|
      { recipient_id: @employee.id, kind: "shift_published", title: "通知#{format('%02d', index)}", created_at: NOW - index.minutes, updated_at: NOW }
    end
    Notification.insert_all!(rows)
    sign_in_as @employee

    get notifications_path
    assert_select "[data-testid='notifications-list'] [data-testid='notification-item']", 20
    assert_select "[data-testid='notifications-list'] [data-testid='notification-title']", text: "通知00"
    assert_select "[data-testid='notifications-page-status']", text: "1 / 3 ページ"
    assert_select "a[data-testid='notifications-next'][href=?]", notifications_path(page: 2)
    assert_select "a[data-testid='notifications-prev']", 0

    get notifications_path(page: 3)
    assert_select "[data-testid='notifications-list'] [data-testid='notification-item']", 5
    assert_select "[data-testid='notifications-list'] [data-testid='notification-title']", text: "通知44"
    assert_select "a[data-testid='notifications-prev'][href=?]", notifications_path(page: 2)

    get notifications_path(page: 99)
    assert_select "[data-testid='notifications-page-status']", text: "3 / 3 ページ"
    get notifications_path(page: "abc")
    assert_select "[data-testid='notifications-page-status']", text: "1 / 3 ページ"
  end

  test "通知を開くと既読になり、関連する画面へ移る。もう一度開いても既読の日時は変わらない" do
    request = @employee.attendance_correction_requests.new(target_date: Date.new(2026, 11, 20), clock_in_time: "09:00",
                                                           clock_out_time: "18:00", reason: "打刻を忘れたため")
    assert request.submit
    note = notify!(@employee, kind: "request_approved", path: Rails.application.routes.url_helpers.approval_request_path(request))
    sign_in_as @employee

    post notification_reading_path(note)
    assert_redirected_to approval_request_path(request)
    assert_response :see_other
    assert_equal NOW, note.reload.read_at

    travel 1.hour
    post notification_reading_path(note)
    assert_equal NOW, note.reload.read_at
    follow_redirect!
    assert_response :success
  end

  test "他の人の通知は、URL を直接送っても既読にできず、移る先も明かさない（存在しない通知と同じ扱い）" do
    note = notify!(@admin, path: "/admin/approvals/1")
    sign_in_as @employee

    post notification_reading_path(note)
    assert_redirected_to notifications_path
    assert_equal "指定された通知が見つかりません。一覧から選び直してください。", flash[:alert]
    assert note.reload.unread?

    post notification_reading_path(id: 999_999, notification_id: 999_999)
    assert_redirected_to notifications_path
    assert_equal "指定された通知が見つかりません。一覧から選び直してください。", flash[:alert]
  end

  test "URL を直接開いた（GET）ときは、既読にせずに一覧へ戻す" do
    note = notify!(@employee)
    sign_in_as @employee
    get notification_reading_path(note)
    assert_redirected_to notifications_path
    assert note.reload.unread?
    get notifications_bulk_reading_path
    assert_redirected_to notifications_path
    assert note.reload.unread?
  end

  test "アプリの外への移り先は使わない（保存できず、保存されていても一覧へ戻す）" do
    invalid = Notification.new(recipient: @employee, kind: "shift_published", title: "x", path: "//evil.example.com/")
    assert_not invalid.valid?
    assert_not Notification.new(recipient: @employee, kind: "shift_published", title: "x", path: "https://evil.example.com/").valid?

    note = notify!(@employee)
    note.update_column(:path, "//evil.example.com/")
    sign_in_as @employee
    post notification_reading_path(note)
    assert_redirected_to notifications_path
    assert note.reload.read?
  end

  test "すべて既読にする：自分の未読だけを既読にする。画面を開いた後に届いた通知は未読のまま" do
    mine = [ notify!(@employee, at: NOW - 2.hours), notify!(@employee, at: NOW - 1.hour) ]
    others = notify!(@admin)
    sign_in_as @employee
    get notifications_path
    assert_select "[data-testid='notifications-read-all']"
    latest_id = mine.last.id
    newer = notify!(@employee, at: NOW)

    post notifications_bulk_reading_path, params: { until_id: latest_id }, headers: { "HTTP_REFERER" => "http://www.example.com#{notifications_path}" }
    assert_redirected_to notifications_path
    assert_equal "2件の通知を既読にしました。", flash[:notice]
    assert mine.all? { |note| note.reload.read? }
    assert newer.reload.unread?, "押す前に届いた新しい通知は、見ていないので未読のまま"
    assert others.reload.unread?, "他の人の通知は変わらない"

    post notifications_bulk_reading_path
    assert newer.reload.read?
    post notifications_bulk_reading_path
    assert_equal "未読の通知はありません。", flash[:notice]

    get notifications_path
    assert_select "[data-testid='notifications-read-all']", 0
  end

  test "すべて既読にする：until_id に他の人の通知の ID を入れても、他の人の通知は既読にならない" do
    others = notify!(@admin)
    notify!(@employee)
    sign_in_as @employee
    post notifications_bulk_reading_path, params: { until_id: others.id + 100 }
    assert others.reload.unread?
    assert_equal 0, @employee.notifications.unread.count
  end

  test "管理者も同じ画面で自分の通知を見られる（申請の通知から承認の詳細へ移る）" do
    request = @employee.attendance_correction_requests.new(target_date: Date.new(2026, 11, 20), clock_in_time: "09:00",
                                                           clock_out_time: "18:00", reason: "打刻を忘れたため")
    assert request.submit
    note = Notification.find_by!(recipient: @admin, subject: request)
    sign_in_as @admin
    get notifications_path
    assert_select "[data-testid='notification-title']", text: "従業 花子 さんから打刻修正の申請が届きました"
    post notification_reading_path(note)
    assert_redirected_to admin_approval_request_path(request)
    follow_redirect!
    assert_response :success
  end
end
