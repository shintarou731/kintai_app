require "test_helper"

# 有給休暇の付与の削除（F10・スプリント 16.1）を画面から確かめる。あわせて、従業員一覧の「5日未満」の印の対象を確かめる。
class Admin::PaidLeaveGrantRemovalsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-26 は木曜日
  NOW = Time.zone.local(2026, 11, 26, 10, 30)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    PaidLeaveGrant.where(user: @employee).delete_all
  end

  teardown { travel_back }

  def grant!(days, granted_on: Date.new(2026, 4, 1), expires_on: nil, user: @employee)
    PaidLeaveGrant.create!(user: user, granted_by: @admin, granted_on: granted_on, days: days.to_s, expires_on: expires_on)
  end

  def leave!(from, to = from, status: "approved", user: @employee)
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: "paid", day_part: "full_day", reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: status, reviewer_id: (@admin.id if status == "approved"), reviewed_at: (NOW if status == "approved"))
    leave
  end

  def remove!(grant, reason)
    post admin_employee_paid_leave_grant_removal_path(@employee, grant), params: { paid_leave_grant_removal: { reason: reason } }
  end

  test "付与の一覧の「削除」から確認画面が開き、付与の内容と削除後の残日数・理由の入力欄が出る" do
    grant = grant!(10, granted_on: Date.new(2026, 10, 1))
    sign_in_as @admin

    get admin_employee_paid_leave_grants_path(@employee)
    assert_select "[data-testid='grant-remove-link'][href=?]", new_admin_employee_paid_leave_grant_removal_path(@employee, grant)

    get new_admin_employee_paid_leave_grant_removal_path(@employee, grant)
    assert_response :success
    assert_select "h1", text: "付与の削除"
    assert_select "[data-testid='removal-granted-on']", text: /2026年10月1日/
    assert_select "[data-testid='removal-days']", text: "10日"
    assert_select "[data-testid='removal-expires-on']", text: /2028年10月1日/
    assert_select "[data-testid='removal-balance-after']", text: /残り 10日 → 残り 0日/
    assert_select "textarea[name='paid_leave_grant_removal[reason]'][required]"
    assert_select "[data-testid='removal-blocked']", 0
  end

  test "理由が空なら 422 でエラーが出て、付与はそのまま残り、削除の記録も作られない" do
    grant = grant!(10)
    sign_in_as @admin

    remove!(grant, "   ")
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /付与を削除できませんでした/
    assert_select ".form-errors li", text: "削除の理由を入力してください"
    assert_not grant.reload.removed?
    assert_nil grant.removal_reason

    # パラメーターが欠けていても 400 にしない
    post admin_employee_paid_leave_grant_removal_path(@employee, grant)
    assert_response :unprocessable_entity
    assert_not grant.reload.removed?
  end

  test "理由を入れて削除すると記録が残り、付与の画面と本人の休暇画面の履歴に「付与の削除」が出て、残日数は 10日 → 0日 になる" do
    grant = grant!(10)
    sign_in_as @admin

    assert_no_difference -> { Notification.count } do
      remove!(grant, "別の従業員の付与と取り違えたため")
    end
    assert_redirected_to admin_employee_paid_leave_grants_path(@employee)
    assert_equal "2026/04/01 付与の 10日（2028/04/01 まで）を削除しました。削除の記録は、付与・取得の履歴に残ります。", flash[:notice]
    grant.reload
    assert_equal [ NOW, @admin, "別の従業員の付与と取り違えたため" ], [ grant.removed_at, grant.removed_by, grant.removal_reason ]

    follow_redirect!
    assert_select "[data-testid='paid-leave-balance']", text: "残り 0日"
    assert_select "[data-testid='grant-row']", 0
    assert_select "[data-testid='removed-grants-count']", text: /削除した付与が 1件/
    assert_select "[data-testid='paid-leave-history-row'][data-kind='removal']", 1 do
      assert_select "[data-testid='paid-leave-history-kind']", text: "付与の削除"
      assert_select "[data-column='date']", text: "11/26(木)"
      assert_select "[data-column='days']", text: /\+10日.*残日数に数えません/m
      assert_select "[data-column='detail']", text: %r{2026/04/01 付与の 10日（有効期限 2028/04/01 まで）を削除しました}
      assert_select "[data-testid='paid-leave-removal-meta']", text: %r{削除：管理 太郎（2026/11/26 10:30）}
      assert_select "[data-testid='paid-leave-removal-reason']", text: "理由：別の従業員の付与と取り違えたため"
    end
    assert_select "[data-testid='paid-leave-history-row'][data-kind='grant']", 0

    delete logout_path
    sign_in_as @employee
    get leave_requests_path
    assert_select "[data-testid='paid-leave-balance']", text: "残り 0日"
    assert_select "[data-testid='paid-leave-requestable']", text: "0日"
    assert_select "[data-testid='paid-leave-history-row'][data-kind='removal']", 1 do
      assert_select "[data-testid='paid-leave-history-kind']", text: "付与の削除"
      assert_select "[data-testid='paid-leave-removal-reason']", text: "理由：別の従業員の付与と取り違えたため"
    end
    get root_path
    assert_select "[data-testid='home-paid-leave-balance']", text: "残り 0日"
  end

  test "承認済み・承認待ちの有給が賄えなくなる付与は、確認画面で理由が出て押せず、送っても 422 で記録は作られない" do
    grant = grant!(2)
    leave!(Date.new(2026, 11, 20))
    leave!(Date.new(2026, 12, 1), status: "pending")
    sign_in_as @admin

    get new_admin_employee_paid_leave_grant_removal_path(@employee, grant)
    assert_select "[data-testid='removal-blocked']", text: /2日 が付与で賄えなくなるため、削除できません/
    assert_select "[data-testid='removal-submit'][disabled]"

    remove!(grant, "誤登録")
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /2日 が付与で賄えなくなるため、削除できません/
    assert_not grant.reload.removed?
    assert_equal 0, PaidLeaveGrant.removed.count
  end

  test "削除済みの付与をもう一度削除しようとすると、一覧に戻され、記録は最初の1件のまま" do
    grant = grant!(5)
    sign_in_as @admin
    remove!(grant, "1回目")

    remove!(grant, "2回目")
    assert_redirected_to admin_employee_paid_leave_grants_path(@employee)
    assert_match "この付与はすでに削除されています（管理 太郎・", flash[:alert]
    assert_equal "1回目", grant.reload.removal_reason

    get new_admin_employee_paid_leave_grant_removal_path(@employee, grant)
    assert_redirected_to admin_employee_paid_leave_grants_path(@employee)
  end

  test "他の従業員の付与・存在しない付与は見つからない扱いにする。URL を直接開いたときは確認画面へ戻す" do
    other = grant!(3, user: @admin)
    grant = grant!(3)
    sign_in_as @admin

    remove!(other, "誤登録")
    assert_redirected_to admin_employee_paid_leave_grants_path(@employee)
    assert_match "見つかりません", flash[:alert]
    assert_not other.reload.removed?

    get new_admin_employee_paid_leave_grant_removal_path(@employee, 999_999)
    assert_redirected_to admin_employee_paid_leave_grants_path(@employee)

    get admin_employee_paid_leave_grant_removal_path(@employee, grant)
    assert_redirected_to new_admin_employee_paid_leave_grant_removal_path(@employee, grant)

    # 以前の物理削除（DELETE）の URL は使えない
    delete "/admin/employees/#{@employee.id}/paid_leaves/#{grant.id}"
    assert_response :not_found
    assert_not grant.reload.removed?
  end

  test "従業員ロールは、確認画面を開けず、削除を直接送っても拒否され、付与は変わらない" do
    grant = grant!(5)
    sign_in_as @employee

    get new_admin_employee_paid_leave_grant_removal_path(@employee, grant)
    assert_redirected_to root_path
    remove!(grant, "自分で消したい")
    assert_redirected_to root_path
    assert_equal "この画面を表示する権限がありません。", flash[:alert]
    assert_not grant.reload.removed?
  end

  test "従業員一覧の「5日未満」の印：付与0件・当年度より前に期限切れの付与だけの人には付けず、年度の後半の付与・当年度中に期限切れの付与の人には付ける" do
    no_grant = User.create!(name: "付与 なし", email: "no-grant@example.com", password: "password123")
    old_grant = User.create!(name: "前年度 期限", email: "old-grant@example.com", password: "password123")
    grant!(10, granted_on: Date.new(2024, 3, 1), expires_on: Date.new(2026, 2, 28), user: old_grant)
    late_grant = User.create!(name: "後半 付与", email: "late-grant@example.com", password: "password123")
    grant!(10, granted_on: Date.new(2026, 10, 1), user: late_grant)
    leave!(Date.new(2026, 11, 19), Date.new(2026, 11, 20), user: late_grant) # 2日
    lapsed = User.create!(name: "年度内 失効", email: "lapsed-grant@example.com", password: "password123")
    grant!(10, granted_on: Date.new(2024, 7, 1), expires_on: Date.new(2026, 6, 30), user: lapsed)
    removed_only = User.create!(name: "削除 のみ", email: "removed-only@example.com", password: "password123", role: "admin")
    assert PaidLeaveGrantRemoval.new(grant: grant!(10, user: removed_only), admin: @admin, reason: "誤登録").save
    sign_in_as @admin

    get admin_employees_path
    assert_response :success
    [ no_grant, old_grant, removed_only ].each do |user|
      assert_select "tr#user_#{user.id} [data-testid='below-annual-target']", 0
      assert_select "tr#user_#{user.id} [data-testid='no-fiscal-year-grants']", text: "当年度の付与なし"
    end
    assert_select "tr#user_#{late_grant.id}" do
      assert_select "[data-column='paid-leave-taken']", text: /2日/
      assert_select "[data-testid='below-annual-target']", text: "5日未満"
    end
    assert_select "tr#user_#{lapsed.id} [data-testid='below-annual-target']", text: "5日未満"
    assert_select "tr#user_#{removed_only.id} [data-column='paid-leave-balance']", text: /0日.*付与なし/m
    assert_select "[data-testid='employees-paid-leave-caption']", text: /当年度に使える有給の付与.*が無い人には付けません/m
  end
end
