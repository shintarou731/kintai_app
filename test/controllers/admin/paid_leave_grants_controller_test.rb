require "test_helper"

# 管理者による有給休暇の付与（F10）と、残日数の表示（休暇・ホーム・従業員一覧）
class Admin::PaidLeaveGrantsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-24 は火曜日
  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    # 従業員のフィクスチャの付与（テスト用の広い期間）を消して、付与の無い状態から確かめる
    PaidLeaveGrant.where(user: @employee).delete_all
  end

  teardown { travel_back }

  def grant!(days, granted_on: Date.new(2026, 4, 1), expires_on: nil, user: @employee)
    PaidLeaveGrant.create!(user: user, granted_by: @admin, granted_on: granted_on, days: days.to_s, expires_on: expires_on)
  end

  def approved_leave!(from, to = from, part: "full_day")
    leave = @employee.leave_requests.new(target_date: from, end_date: to, leave_type: "paid", day_part: part, reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  test "付与の画面に、残日数・付与の入力（初期値：今日・10日・2年後）・付与の一覧・履歴が出る" do
    grant!(10)
    approved_leave!(Date.new(2026, 11, 20), Date.new(2026, 11, 24))
    sign_in_as @admin

    get admin_employee_paid_leave_grants_path(@employee)
    assert_response :success
    assert_select "h1", text: /従業 花子 さんの有給休暇/
    assert_select "[data-testid='paid-leave-balance']", text: "残り 8日"
    assert_select "input[name='paid_leave_grant[granted_on]'][value='2026-11-24']"
    assert_select "input[name='paid_leave_grant[days]'][value='10']"
    assert_select "input[name='paid_leave_grant[expires_on]'][value='2028-11-24']"
    assert_select "[data-testid='grant-row']", 1 do
      assert_select "[data-column='used']", text: "2日"
      assert_select "[data-column='remaining']", text: "8日"
    end
    assert_select "[data-testid='paid-leave-history-row'][data-kind='usage']", text: /11\/20\(金\)〜11\/24\(火\).*2日・土日祝を除く/m
    assert_select "[data-testid='paid-leave-history-row'][data-kind='grant']", text: /\+10日/
  end

  test "付与日・日数・有効期限を入れて付与でき、有効期限が空なら付与日の2年後になる" do
    sign_in_as @admin

    post admin_employee_paid_leave_grants_path(@employee),
         params: { paid_leave_grant: { granted_on: "2026-10-01", days: "7.5", expires_on: "", note: "定期付与" } }
    assert_redirected_to admin_employee_paid_leave_grants_path(@employee)
    assert_equal "従業 花子 さんに有給休暇を 7.5日 付与しました（2026/10/01 付与・2028/10/01 まで有効）。", flash[:notice]
    grant = PaidLeaveGrant.find_by!(user: @employee)
    assert_equal [ Date.new(2026, 10, 1), 15, Date.new(2028, 10, 1), @admin, "定期付与" ],
                 [ grant.granted_on, grant.half_days, grant.expires_on, grant.granted_by, grant.note ]

    post admin_employee_paid_leave_grants_path(@employee),
         params: { paid_leave_grant: { granted_on: "2026-11-01", days: "3", expires_on: "2027-03-31" } }
    assert_equal Date.new(2027, 3, 31), PaidLeaveGrant.where(user: @employee).order(:id).last.expires_on

    follow_redirect!
    assert_select "[data-testid='paid-leave-balance']", text: "残り 10.5日"
  end

  test "入力に誤りがあれば 422 で、上部のメッセージと項目のエラーを出し、付与しない" do
    sign_in_as @admin

    post admin_employee_paid_leave_grants_path(@employee),
         params: { paid_leave_grant: { granted_on: "2026-11-25", days: "0.3", expires_on: "" } }
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /有給休暇を付与できませんでした/
    assert_select ".form-errors li", text: "付与日に未来の日付は指定できません（今日までの日付にしてください）"
    assert_select ".form-errors li", text: "日数は0.5日単位で入力してください（例：10、7.5）"
    assert_equal 0, PaidLeaveGrant.where(user: @employee).count

    # パラメーターが欠けていても 400 にしない
    post admin_employee_paid_leave_grants_path(@employee)
    assert_response :unprocessable_entity
  end

  test "従業員ロールは付与の画面を開けず、付与もできない" do
    sign_in_as @employee

    get admin_employee_paid_leave_grants_path(@employee)
    assert_redirected_to root_path
    post admin_employee_paid_leave_grants_path(@employee), params: { paid_leave_grant: { granted_on: "2026-11-01", days: "20" } }
    assert_redirected_to root_path
    assert_equal 0, PaidLeaveGrant.where(user: @employee).count
  end

  test "存在しない従業員は一覧に戻す" do
    sign_in_as @admin
    get admin_employee_paid_leave_grants_path(employee_id: 999_999)
    assert_redirected_to admin_employees_path
  end

  test "従業員一覧に、有給の残日数と当年度の取得日数が出て、5日未満の人に印が付く" do
    grant!(20)
    approved_leave!(Date.new(2026, 11, 16), Date.new(2026, 11, 20)) # 5日
    approved_leave!(Date.new(2026, 12, 1), part: "morning") # 予定 0.5日
    sign_in_as @admin

    get admin_employees_path
    assert_response :success
    assert_select "tr#user_#{@employee.id}" do
      assert_select "[data-column='paid-leave-balance']", text: /14.5日/
      assert_select "[data-column='paid-leave-taken']", text: /5.5日.*うち予定 0.5日/m
      assert_select "[data-testid='below-annual-target']", 0
    end
    # 管理者（フィクスチャの付与あり・取得なし）は5日未満
    assert_select "tr#user_#{@admin.id} [data-testid='below-annual-target']", text: "5日未満"
    assert_select "[data-testid='employees-paid-leave-caption']", text: /2026\/04\/01〜2027\/03\/31/
  end

  test "付与が0件で承認済みの有給があると、一覧に「超過」、休暇とホームに残り0日と注意が出る" do
    approved_leave!(Date.new(2026, 11, 20), Date.new(2026, 11, 24))
    sign_in_as @admin
    get admin_employees_path
    assert_select "tr#user_#{@employee.id} [data-testid='paid-leave-shortage-badge']", text: "超過 2日"
    assert_select "tr#user_#{@employee.id} [data-column='paid-leave-balance']", text: /0日/

    delete logout_path
    sign_in_as @employee
    get leave_requests_path
    assert_select "[data-testid='paid-leave-balance']", text: "残り 0日"
    assert_select "[data-testid='paid-leave-shortage']", text: /付与された日数を超えて取得した有給休暇が 2日 あります/
    get root_path
    assert_select "[data-testid='home-paid-leave-balance']", text: "残り 0日"
    assert_select "[data-testid='home-paid-leave-shortage']", text: /2日/
  end

  test "従業員の休暇画面とホームに残日数（0.5日単位）が出て、休暇画面に付与・取得の履歴が出る" do
    grant!(10)
    approved_leave!(Date.new(2026, 11, 20), Date.new(2026, 11, 24))
    approved_leave!(Date.new(2026, 11, 26), part: "afternoon")
    sign_in_as @employee

    get root_path
    assert_select "[data-testid='home-paid-leave-balance']", text: "残り 7.5日"

    get leave_requests_path
    assert_select "[data-testid='paid-leave-balance']", text: "残り 7.5日"
    assert_select "[data-testid='paid-leave-requestable']", text: "7.5日"
    assert_select "[data-testid='leave-form'][data-leave-form-paid-requestable-value='7.5']"
    rows = css_select("[data-testid='paid-leave-history-row']")
    assert_equal %w[usage usage grant], rows.map { |row| row["data-kind"] }
    assert_select "[data-testid='paid-leave-history-row'][data-kind='usage'] [data-column='days']", text: "−0.5日"
    assert_select "[data-testid='paid-leave-history-row'][data-kind='grant'] [data-column='date']", text: "4/1(水)"
  end

  test "残日数を超える有給の申請は 422 になり、エラーが出る" do
    grant!(1)
    sign_in_as @employee

    post leave_requests_path, params: { leave_request: { leave_type: "paid", target_date: "2026-11-26", end_date: "2026-11-27",
                                                         day_part: "full_day", reason: "私用" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors li", text: /有給休暇の残日数が足りないため申請できません（この申請 2日・休暇の日付に使える残り 1日）/
    assert_equal 0, @employee.leave_requests.count
  end

  test "承認画面の休暇の詳細に、有給の残日数と承認後の残りが出る。足りなければ承認できない" do
    grant!(2)
    leave = @employee.leave_requests.new(target_date: Date.new(2026, 11, 26), end_date: Date.new(2026, 11, 27),
                                         leave_type: "paid", day_part: "full_day", reason: "私用")
    assert leave.submit
    sign_in_as @admin

    get admin_approval_request_path(leave)
    assert_select "[data-testid='leave-paid-balance']", text: /今は 残り 2日。.*承認されると 0日 になります/m

    PaidLeaveGrant.where(user: @employee).update_all(half_days: 2)
    get admin_approval_request_path(leave)
    assert_select "[data-testid='leave-paid-shortfall']", text: /残日数が足りません（休暇の日付に使える残り 1日）/
    post admin_approval_request_review_path(leave), params: { approval_review: { decision: "approve" } }
    assert_response :unprocessable_entity
    assert leave.reload.pending?
  end

  test "有給を付与すると、本人に通知が届く（F16）。付与できなかったときは届かない" do
    sign_in_as @admin
    post admin_employee_paid_leave_grants_path(@employee), params: { paid_leave_grant: { granted_on: "2026-11-24", days: "10", expires_on: "" } }
    note = Notification.find_by!(recipient: @employee, kind: "paid_leave_granted")
    assert_equal "有給休暇が10日付与されました", note.title
    assert_match "残日数は10日です", note.body
    assert_equal leave_requests_path, note.path

    post admin_employee_paid_leave_grants_path(@employee), params: { paid_leave_grant: { granted_on: "2026-11-24", days: "abc" } }
    assert_equal 1, Notification.where(recipient: @employee).count
  end
end
