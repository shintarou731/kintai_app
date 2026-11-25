require "test_helper"

# 本人のアカウント情報（F2 の追加分・スプリント17）
class AccountsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-24 は火曜日
  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @employee = users(:employee)
    @admin = users(:admin)
    travel_to NOW
  end

  teardown { travel_back }

  def approved_paid_leave!(user, from, to)
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: "paid", day_part: "full_day", reason: "私用のため")
    assert leave.submit, leave.errors.full_messages.inspect
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  test "未ログインではアカウント情報を開けない" do
    get account_path
    assert_redirected_to login_path
  end

  test "従業員は自分のアカウント情報（基本情報・有給休暇・パスワード・アカウントの状態）を見られる" do
    sign_in_as @employee
    get account_path
    assert_response :success

    assert_select "title", /アカウント情報/
    assert_select "h1", /従業 花子 さん/
    assert_select "h1 .badge", "有効"
    assert_select "[data-testid='account-name']", "従業 花子"
    assert_select "[data-testid='account-email']", "hanako@example.com"
    assert_select "[data-testid='account-hired-on']", "2024/10/01"
    assert_select "[data-testid='account-role']", "従業員"
    assert_select "[data-testid='account-employment-type']", "パート・アルバイト"
    assert_select "[data-testid='account-readonly-note']", /管理者に変更を依頼/
    assert_select "[data-testid='account-admin-edit-link']", count: 0

    # 欄の並びは従業員の編集画面と同じ
    titles = css_select(".card__title").map { |node| node.text.strip }
    assert_equal %w[基本情報 有給休暇 パスワード アカウントの状態], titles
    labels = css_select("[data-testid='account-basic-card'] dt").map { |node| node.text.strip }
    assert_equal %w[氏名 メールアドレス 入社日 役割 雇用区分], labels

    assert_select "[data-testid='account-leaves-link'][href='#{leave_requests_path}']"
    assert_select "[data-testid='account-password-link'][href='#{edit_password_path}']", "パスワードを変更する"
    assert_select "[data-testid='account-status-card'] .badge", "有効"
  end

  test "閲覧専用：入力欄・保存ボタン・無効化ボタンが無い" do
    [ @employee, @admin ].each do |user|
      sign_in_as user
      get account_path
      assert_select "main form", count: 0
      assert_select "main input, main select, main textarea, main button", count: 0
      assert_select "main a, main button", text: /無効にする|有効に戻す|更新する|保存/, count: 0
      assert_no_match(/無効にする|有効に戻す|更新する|保存する/, css_select("main").text)
      delete logout_path
    end
  end

  test "管理者も自分のアカウント情報を見られ、変更は「従業員」画面への案内が出る" do
    sign_in_as @admin
    get account_path
    assert_response :success
    assert_select "[data-testid='account-name']", "管理 太郎"
    assert_select "[data-testid='account-role']", "管理者"
    assert_select "[data-testid='account-employment-type']", "正社員"
    assert_select "[data-testid='account-hired-on']", "2020/04/01"
    assert_select "[data-testid='account-admin-edit-link'][href='#{edit_admin_employee_path(@admin, from: 'account')}']"
    # 状態と役割の補足は、編集画面（本人）の文言にそろえる
    assert_select "[data-testid='account-status-card']", /ご自身のアカウントは無効にできません/
    assert_select "[data-testid='account-status-card']", text: /状態の変更は、管理者が行います/, count: 0
    assert_select ".account-fields__hint", /ご自身の役割は変更できません/
  end

  test "入社日が未設定なら「未設定」と出る" do
    @employee.update_column(:hired_on, nil)
    sign_in_as @employee
    get account_path
    assert_select "[data-testid='account-hired-on']", "未設定"
  end

  test "有給の残日数と当年度の取得日数は、休暇画面と従業員一覧と同じ値になる" do
    approved_paid_leave!(@employee, Date.new(2026, 11, 26), Date.new(2026, 11, 27)) # 2日
    approved_paid_leave!(@employee, Date.new(2026, 11, 30), Date.new(2026, 11, 30)) # 1日

    sign_in_as @employee
    get account_path
    assert_select "[data-testid='account-paid-leave-balance']", "残り 37日"
    assert_select "[data-testid='account-paid-leave-taken']", "3日"

    get leave_requests_path
    assert_select "[data-testid='paid-leave-balance']", "残り 37日"
    assert_select "[data-testid='paid-leave-fiscal-taken']", /\A\s*3日/

    delete logout_path
    sign_in_as @admin
    get admin_employees_path
    row = css_select("tr").find { |tr| tr.text.include?("hanako@example.com") }
    assert_equal "37日", row.at_css("[data-column='paid-leave-balance'] a").text.strip
    assert_match(/\A3日/, row.at_css("[data-column='paid-leave-taken']").text.strip)
  end

  test "URL に他の人の ID を入れても、他の人の情報は表示されない" do
    sign_in_as @employee

    get account_path(id: @admin.id)
    assert_response :success
    assert_select "[data-testid='account-name']", "従業 花子"
    assert_no_match(/管理 太郎|admin@example\.com/, css_select("main").text)

    get account_path(user_id: @admin.id, user: { id: @admin.id })
    assert_select "[data-testid='account-email']", "hanako@example.com"

    # ID 付きの URL は用意していない
    [ "/account/#{@admin.id}", "/accounts/#{@admin.id}", "/accounts" ].each do |path|
      get path
      assert_response :not_found, "#{path} は 404 になるべき"
    end
  end

  test "管理者も URL で他の従業員を指定できない" do
    sign_in_as @admin
    get account_path(id: @employee.id)
    assert_select "[data-testid='account-name']", "管理 太郎"
    assert_no_match(/従業 花子|hanako@example\.com/, css_select("main").text)
  end

  test "直接送信（PATCH・PUT・POST・DELETE）しても何も変わらない" do
    sign_in_as @employee
    before = @employee.reload.attributes
    attack = { user: { name: "書き換え", email: "x@example.com", role: "admin", employment_type: "full_time", active: false },
               id: @admin.id }

    %i[patch put post delete].each do |verb|
      send(verb, account_path, params: attack)
      assert_response :not_found, "#{verb.upcase} /account は受け付けない"
      send(verb, "/account/#{@admin.id}", params: attack)
      assert_response :not_found
    end

    assert_equal before, @employee.reload.attributes
    assert @admin.reload.active?
    assert_equal "管理 太郎", @admin.name
  end

  test "ヘッダーの歯車と名前から、アカウント情報へ移れる" do
    [ @employee, @admin ].each do |user|
      sign_in_as user
      get root_path
      assert_select ".header__user a[data-testid='header-settings'][href='#{account_path}'][aria-label='設定（アカウント情報）']" do
        assert_select "svg[aria-hidden='true']"
      end
      assert_select "[data-testid='header-settings'][aria-current]", count: 0
      assert_select "a[data-testid='current-user-name'][href='#{account_path}']", user.name
      assert_select "a[data-testid='current-user-name'][href='#{edit_password_path}']", count: 0

      get account_path
      assert_select "[data-testid='header-settings'].is-active[aria-current='page']"
      delete logout_path
    end
  end

  test "パスワード変更画面からアカウント情報へ戻れ、変更後もアカウント情報に戻る" do
    sign_in_as @employee
    get edit_password_path
    assert_select "[data-testid='password-back-link'][href='#{account_path}']", "← アカウント情報に戻る"
    assert_select ".form__actions a[href='#{account_path}']", "キャンセル"
    assert_select "[data-testid='header-settings'].is-active"
    assert_select "[data-testid='header-settings'][aria-current]", count: 0
  end
end
