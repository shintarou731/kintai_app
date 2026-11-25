require "test_helper"

# 承認画面（F8）に休暇申請・取消申請（F9）が並び、承認・却下できること。
# あわせて、スプリント8の評価の指摘（422 の上部メッセージ・承認待ちの件数）を確かめる
class Admin::LeaveApprovalsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-24 は火曜日
  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    travel_to NOW
  end

  teardown { travel_back }

  def d(day)
    Date.new(2026, 11, day)
  end

  def leave!(user: @employee, from: d(26), to: d(27), type: "paid", part: "full_day")
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: part, reason: "私用のため")
    assert leave.submit, leave.errors.full_messages.inspect
    leave
  end

  def approve_directly(leave)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  def cancellation!(leave, user: @employee)
    request = user.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "予定が変わったため")
    assert request.submit, request.errors.full_messages.inspect
    request
  end

  def second_admin
    User.create!(name: "管理 二郎", email: "admin2@example.com", password: "password123", role: "admin",
                 hired_on: Date.new(2021, 4, 1))
  end

  def post_review(request, decision:, comment: nil)
    post admin_approval_request_review_path(request), params: { approval_review: { decision: decision, comment: comment } }
  end

  def switch_to(user)
    delete logout_path
    sign_in_as user
  end

  test "休暇申請・取消申請が承認待ちの一覧に、種類・期間・内容つきで並ぶ" do
    leave = leave!(from: d(26), to: d(30))
    approved = approve_directly(leave!(from: d(2) + 30, to: d(2) + 30))
    cancel = cancellation!(approved)
    sign_in_as @admin

    get admin_approval_requests_path
    assert_select "[data-testid='approval-row']", 2
    assert_select "##{ActionView::RecordIdentifier.dom_id(leave)}" do
      assert_select "[data-column=kind]", text: "休暇"
      assert_select "[data-column=target-date]", text: "11/26(木)〜11/30(月)"
      assert_select "[data-column=summary]", text: "有給休暇・全日（3日・土日祝を除く）"
    end
    assert_select "##{ActionView::RecordIdentifier.dom_id(cancel)}" do
      assert_select "[data-column=kind]", text: "休暇取消"
      assert_select "[data-column=summary]", text: "有給休暇・全日（1日） の取消"
    end
  end

  test "休暇申請の詳細に内容が出て、承認すると承認済みになり、本人の勤怠履歴に表示される" do
    leave = leave!(from: d(26), to: d(27))
    sign_in_as @admin

    get admin_approval_request_path(leave)
    assert_response :success
    assert_select "[data-testid='leave-details']" do
      assert_select "[data-testid='leave-type']", text: "有給休暇"
      assert_select "[data-testid='leave-period']", text: "2026年11月26日(木)〜11月27日(金)（2日間）"
    end
    assert_select "[data-testid='approval-effect']", text: /本人の勤怠履歴の該当日に「有給（全日）」と表示されます/
    assert_select "[data-testid='approve-button']:not([disabled])"

    post_review(leave, decision: "approve")
    assert_redirected_to admin_approval_requests_path
    assert_equal "従業 花子 さんの 11/26(木)〜11/27(金) の休暇申請を承認しました。勤怠履歴の該当日に「有給（全日）」と表示されます。有給休暇の残日数から2日引きました。",
                 flash[:notice]
    assert leave.reload.approved?

    switch_to @employee
    get attendances_path(month: "2026-11")
    assert_select "tr[data-date='2026-11-26'].history-row--leave [data-testid='day-leave'][data-leave-status=approved]", text: "有給（全日）"
    assert_select "tr[data-date='2026-11-27'] [data-testid='day-leave']", text: "有給（全日）"
    assert_select "tr[data-date='2026-11-25'] [data-testid='day-leave']", 0
    assert_select "[data-testid='leave-totals']", text: /有給 2日/
  end

  test "休暇申請を却下するとコメントが必須。却下後は本人の勤怠履歴に表示されない" do
    leave = leave!(from: d(26), to: d(26), part: "morning")
    sign_in_as @admin

    post_review(leave, decision: "reject", comment: "")
    assert_response :unprocessable_entity
    assert leave.reload.pending?

    post_review(leave, decision: "reject", comment: "その日は棚卸しのため")
    assert_equal "従業 花子 さんの 11/26(木) の休暇申請を却下しました。休暇は登録されません。", flash[:notice]
    assert leave.reload.rejected?

    switch_to @employee
    get attendances_path(month: "2026-11")
    assert_select "tr[data-date='2026-11-26'] [data-testid='day-leave']", 0
    get approval_request_path(leave)
    assert_select "[data-testid='review-comment']", text: "その日は棚卸しのため"
  end

  test "承認待ちの休暇は勤怠履歴に「申請中」として出て、半休は「有給（午前半休）」と表示される" do
    leave!(from: d(26), to: d(26), part: "morning")
    approve_directly(leave!(from: d(30), to: d(30), part: "afternoon", type: "special"))
    sign_in_as @employee

    get attendances_path(month: "2026-11")
    assert_select "tr[data-date='2026-11-26'] [data-testid='day-leave'][data-leave-status=pending]", text: "有給（午前半休）・申請中"
    assert_select "tr[data-date='2026-11-26'].history-row--leave", 0
    assert_select "tr[data-date='2026-11-30'] [data-testid='day-leave']", text: "特別休暇（午後半休）"
    assert_select "[data-testid='leave-totals']", text: /特別休暇 0.5日/
  end

  test "承認時にも期間の重なりを確かめ直し、重なっていれば承認ボタンが押せず、直接送っても 422" do
    leave = leave!(from: d(26), to: d(27))
    other = leave!(from: d(30), to: d(30))
    other.update_columns(target_date: d(27), end_date: d(27), status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    sign_in_as @admin

    get admin_approval_request_path(leave)
    assert_select "[data-testid='approval-blockers']", text: /承認済みの 11\/27\(金\) の有給休暇（全日） と期間が重なるため承認できません/
    assert_select "[data-testid='approve-button'][disabled]"

    post_review(leave, decision: "approve")
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /承認できませんでした：承認済みの 11\/27\(金\)/
    assert leave.reload.pending?
  end

  test "期間中に勤務の記録があれば、承認画面で知らせる" do
    @employee.attendances.create!(work_date: d(26), clock_in_at: d(26).in_time_zone.change(hour: 9))
    leave = leave!(from: d(26), to: d(27), type: "absence")
    sign_in_as @admin

    get admin_approval_request_path(leave)
    assert_select "[data-testid='leave-attendance-notice']", text: /11\/26\(木\) に出勤の記録があります/
  end

  test "取消申請を承認すると休暇が取り消され、勤怠履歴から消える。却下なら休暇は有効のまま" do
    leave = approve_directly(leave!(from: d(26), to: d(27)))
    cancel = cancellation!(leave)
    sign_in_as @admin

    get admin_approval_request_path(cancel)
    assert_select "[data-testid='leave-details']", text: /取り消す休暇/
    assert_select "[data-testid='approval-effect']", text: /この休暇は取り消され/

    post_review(cancel, decision: "reject", comment: "人手が足りないため")
    assert_equal "従業 花子 さんの 11/26(木)〜11/27(金) の休暇取消申請を却下しました。休暇は取り消されず、有効のままです。", flash[:notice]
    assert leave.reload.effective?

    second = cancellation!(leave)
    post_review(second, decision: "approve")
    assert_equal "従業 花子 さんの 11/26(木)〜11/27(金) の休暇取消申請を承認しました。休暇を取り消しました（勤怠履歴の表示も消えます）。有給休暇の残日数に2日戻しました。",
                 flash[:notice]
    assert leave.reload.cancelled?

    get admin_approval_requests_path(status: "processed")
    assert_select "##{ActionView::RecordIdentifier.dom_id(leave)} [data-testid='leave-cancelled']", text: "取消済み"

    switch_to @employee
    get attendances_path(month: "2026-11")
    assert_select "tr[data-date='2026-11-26'] [data-testid='day-leave']", 0
    get approval_request_path(leave)
    assert_select "[data-testid='cancellation-history'] li", 2
  end

  test "処理が遅れて開始日を過ぎた取消申請には、承認画面で注意を出す" do
    leave = approve_directly(leave!(from: d(25), to: d(25)))
    cancel = cancellation!(leave)

    travel_to Time.zone.local(2026, 11, 26, 9) do
      sign_in_as @admin
      get admin_approval_request_path(cancel)
      assert_select "[data-testid='cancellation-passed-notice']", text: /開始日を過ぎています/
    end
  end

  # ---- 自己承認ルール ----

  test "有効な管理者が2人以上なら、自分の休暇申請は詳細に操作が出ず、直接送っても拒否される" do
    other_admin = second_admin
    own = leave!(user: @admin)
    sign_in_as @admin

    get admin_approval_request_path(own)
    assert_select "[data-testid='self-review-notice']", text: /ご自身の申請は他の管理者が処理します/
    assert_select "[data-testid='review-form']", 0

    post_review(own, decision: "approve")
    assert_response :unprocessable_entity
    assert own.reload.pending?

    switch_to other_admin
    post_review(own, decision: "approve")
    assert_redirected_to admin_approval_requests_path
    assert own.reload.approved?
  end

  test "有効な管理者が1人なら、自分の休暇申請・取消申請を承認できる" do
    own = leave!(user: @admin)
    sign_in_as @admin

    get admin_approval_request_path(own)
    assert_select "[data-testid='self-review-notice']", text: /管理者が1名のため、ご自身の申請を承認・却下できます/
    post_review(own, decision: "approve")
    assert own.reload.approved?

    cancel = cancellation!(own, user: @admin)
    post_review(cancel, decision: "approve")
    assert own.reload.cancelled?
    assert_equal @admin, cancel.reload.reviewer
  end

  # ---- スプリント8の評価の指摘 ----

  test "承認・却下が 422 になったとき、画面上部のメッセージでも知らせる" do
    leave = leave!
    sign_in_as @admin

    post_review(leave, decision: "reject", comment: " ")
    assert_response :unprocessable_entity
    assert_select ".flash-area .flash--alert",
                  text: "却下できませんでした：コメントを入力してください（却下するときは、理由をコメントに書いてください）"
    assert_select "[data-testid='review-section'] .form-errors li", text: /コメントを入力してください/
  end

  test "承認待ちのバッジは、自分が処理できる件数だけを数える（有効な管理者が2人以上なら自分の申請を除く）" do
    leave!(user: @admin, from: d(26), to: d(26))
    sign_in_as @admin

    get root_path
    assert_select "[data-testid='admin-menu-badge']", text: "1", message: "管理者が1人なら自分の申請も数える"

    second_admin
    get root_path
    assert_select "[data-testid='admin-menu-badge']", 0
    assert_select "[data-testid='approval-badge']", 0

    leave!(user: @employee, from: d(26), to: d(26))
    get admin_approval_requests_path
    assert_select "[data-testid='admin-menu-badge']", text: "1"
    assert_select "[data-testid='filter-pending'] .tabs__count", text: "2", message: "一覧のタブは自分の申請も含めた件数"
    assert_select "[data-testid='self-review-summary']", text: /あなたが処理できる申請（1件）だけを数えています/
  end

  # ---- 祝日（スプリント9.2） ----

  test "承認画面でも休日を除いた日数が出て、休日だけの有給休暇は承認ボタンが押せず、直接送っても 422" do
    holiday_leave = @employee.leave_requests.new(target_date: d(23), end_date: d(23), leave_type: "paid", day_part: "full_day",
                                                 reason: "祝日の判定を入れる前に申請された休暇")
    holiday_leave.save!(validate: false)
    sign_in_as @admin

    get admin_approval_requests_path
    assert_select "##{ActionView::RecordIdentifier.dom_id(holiday_leave)} [data-column=summary]", text: "有給休暇・全日（0日・土日祝を除く）"

    get admin_approval_request_path(holiday_leave)
    assert_select "[data-testid='approval-blockers']", text: /期間がすべて休日（土日・祝日）のため、有給休暇の日数が0日になり承認できません/
    assert_select "[data-testid='approve-button'][disabled]"
    assert_select "[data-testid='leave-days-off']", text: "除いた休日：11/23(月) 勤労感謝の日"

    post_review(holiday_leave, decision: "approve")
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /承認できませんでした：期間がすべて休日/
    assert holiday_leave.reload.pending?

    # 却下はできる
    post_review(holiday_leave, decision: "reject", comment: "祝日のため、有給休暇は不要です")
    assert holiday_leave.reload.rejected?
  end

  test "祝日を含む休暇の承認画面に、休日を除いた日数が出る（11/20〜11/24 は2日）" do
    leave = leave!(from: d(20), to: d(24))
    sign_in_as @admin

    get admin_approval_requests_path
    assert_select "##{ActionView::RecordIdentifier.dom_id(leave)} [data-column=summary]", text: "有給休暇・全日（2日・土日祝を除く）"
    get admin_approval_request_path(leave)
    assert_select "[data-testid='leave-days']", text: /2日/
    assert_select "[data-testid='approve-button']:not([disabled])"
  end

  test "（スプリント9.1の所見）処理済みの申請の詳細には、操作の無い「承認・却下」カードを出さない" do
    leave = approve_directly(leave!(from: d(26), to: d(26)))
    sign_in_as @admin

    get admin_approval_request_path(leave)
    assert_select "[data-testid='review-result']"
    assert_select "[data-testid='review-section']", 0
    assert_select "[data-testid='direct-cancellation-section']"

    # 承認待ちの申請には出る
    get admin_approval_request_path(leave!(from: d(30), to: d(30)))
    assert_select "[data-testid='review-section'] [data-testid='review-form']"
  end
end
