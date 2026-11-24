require "test_helper"
require "minitest/mock"

# 管理者による承認済み休暇の直接取消（F9 の追加分）：承認画面の休暇の詳細から取り消す
class Admin::LeaveDirectCancellationsControllerTest < ActionDispatch::IntegrationTest
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

  def leave!(user: @employee, from: d(26), to: d(27), type: "paid", part: "full_day", status: "approved")
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: part, reason: "私用のため")
    assert leave.submit, leave.errors.full_messages.inspect
    leave.update_columns(status: status, reviewer_id: @admin.id, reviewed_at: NOW - 1.day) unless status == "pending"
    leave.reload
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

  def post_cancel(leave, reason: "本人から電話で依頼があったため")
    post admin_approval_request_cancellation_path(leave), params: { leave_direct_cancellation: { reason: reason } }
  end

  def switch_to(user)
    delete logout_path
    sign_in_as user
  end

  # ---- 画面と取消 ----

  test "承認済みの休暇の詳細に、開始日が未来・当日・過去のどれでも直接取消のフォームが出る" do
    sign_in_as @admin
    [ leave!(from: d(26), to: d(26)), leave!(from: d(24), to: d(24)), leave!(from: d(16), to: d(17)) ].each do |leave|
      get admin_approval_request_path(leave)
      assert_response :success
      assert_select "[data-testid='direct-cancellation-section']" do
        assert_select "[data-testid='direct-cancellation-form'][action='#{admin_approval_request_cancellation_path(leave)}']" do
          assert_select "textarea[name='leave_direct_cancellation[reason]'][required]"
          assert_select "[data-testid='direct-cancellation-submit'][data-turbo-confirm*='従業 花子 さんの']"
        end
      end
    end
  end

  test "当日の休暇を理由つきで取り消すと、取消済みになり、詳細・処理済み一覧・本人の画面に記録が出る" do
    leave = leave!(from: d(24), to: d(24))
    sign_in_as @admin

    post_cancel(leave)
    assert_redirected_to admin_approval_request_path(leave)
    assert_equal "従業 花子 さんの 11/24(火) の有給休暇（全日）を取り消しました。本人の勤怠履歴の該当日から休暇の表示が消えます。",
                 flash[:notice]
    leave.reload
    assert leave.directly_cancelled?
    assert_equal @admin, leave.cancelled_by
    assert_equal "本人から電話で依頼があったため", leave.cancellation_reason

    # 休暇の詳細（承認画面）
    follow_redirect!
    assert_select "[data-testid='leave-cancelled']", text: "取消済み"
    assert_select "[data-testid='leave-cancelled-at']", text: "2026年11月24日(火) 10:30"
    assert_select "[data-testid='leave-cancelled-method']", text: "管理者による直接取消"
    assert_select "[data-testid='leave-cancelled-by']", text: "管理 太郎"
    assert_select "[data-testid='leave-cancellation-reason']", text: "本人から電話で依頼があったため"
    assert_select "[data-testid='direct-cancellation-form']", 0
    assert_select "[data-testid='direct-cancellation-done']", text: /管理 太郎（11\/24 10:30）に直接取り消されました/

    # 承認画面の処理済み一覧
    get admin_approval_requests_path(status: "processed")
    assert_select "##{ActionView::RecordIdentifier.dom_id(leave)}" do
      assert_select "[data-testid='leave-cancelled']", text: "取消済み"
      assert_select "[data-testid='direct-cancellation-by']", text: "取消：管理 太郎"
      assert_select "[data-testid='direct-cancellation-at']", text: "取消：11/24 10:30"
      assert_select "[data-testid='direct-cancellation-reason']", text: "取消の理由：本人から電話で依頼があったため"
    end

    # 本人の休暇の詳細と勤怠履歴
    switch_to @employee
    get approval_request_path(leave)
    assert_select "[data-testid='leave-cancelled-by']", text: "管理 太郎"
    assert_select "[data-testid='leave-cancellation-reason']", text: "本人から電話で依頼があったため"
    assert_select "[data-testid='processed-note']", text: /管理者（管理 太郎 さん）が 2026年11月24日\(火\) 10:30 に取り消しました/
    get attendances_path(month: "2026-11")
    assert_select "[data-testid='day-leave']", 0
  end

  test "処理済み一覧は、直接取り消した休暇を取り消した日時で並べる" do
    old_leave = leave!(from: d(16), to: d(16))
    other = leave!(from: d(30), to: d(30))
    other.update_columns(reviewed_at: NOW - 1.hour)
    sign_in_as @admin

    post_cancel(old_leave)
    get admin_approval_requests_path(status: "processed")
    rows = css_select("[data-testid='approval-row']").map { |row| row["id"] }
    assert_equal [ ActionView::RecordIdentifier.dom_id(old_leave), ActionView::RecordIdentifier.dom_id(other) ], rows
  end

  test "理由が空なら取り消せず、422 で画面上部とフォームにエラーが出て、休暇は承認済みのまま" do
    leave = leave!
    sign_in_as @admin

    post_cancel(leave, reason: "  ")
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /休暇を取り消せませんでした：取消の理由を入力してください/
    assert_select "[data-testid='direct-cancellation-form'] .form-errors", text: /取消の理由を入力してください/
    assert leave.reload.effective?

    # パラメーターが欠けていても 400 にせず、同じエラーにする
    post admin_approval_request_cancellation_path(leave), params: { leave_direct_cancellation: "x" }
    assert_response :unprocessable_entity
    post admin_approval_request_cancellation_path(leave)
    assert_response :unprocessable_entity
    assert leave.reload.effective?
  end

  test "承認待ち・却下の休暇には取消の操作が出ず、直接送っても取り消せない" do
    pending = leave!(from: d(26), to: d(26), status: "pending")
    rejected = leave!(from: d(30), to: d(30), status: "rejected")
    sign_in_as @admin

    [ pending, rejected ].each do |leave|
      get admin_approval_request_path(leave)
      assert_select "[data-testid='direct-cancellation-section']", 0
      post_cancel(leave)
      assert_response :unprocessable_entity
      assert_nil leave.reload.cancelled_at
    end
  end

  test "すでに取り消された休暇をもう一度送っても、最初の取消の記録が残る" do
    leave = leave!
    sign_in_as @admin
    post_cancel(leave, reason: "1回目")

    post_cancel(leave, reason: "2回目")
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /この休暇はすでに取り消されています/
    assert_equal "1回目", leave.reload.cancellation_reason
  end

  test "休暇以外の申請・存在しない ID は、承認画面の一覧に戻して知らせる" do
    correction = @employee.attendance_correction_requests.new(target_date: d(20), reason: "打刻忘れ",
                                                              requested_clock_in_at: Time.zone.local(2026, 11, 20, 9),
                                                              requested_clock_out_at: Time.zone.local(2026, 11, 20, 18))
    correction.save!(validate: false)
    sign_in_as @admin

    [ correction.id, 99_999 ].each do |id|
      post admin_approval_request_cancellation_path(id), params: { leave_direct_cancellation: { reason: "x" } }
      assert_redirected_to admin_approval_requests_path
      assert_equal "指定された申請が見つかりません。一覧から選び直してください。", flash[:alert]
    end
    assert correction.reload.pending?
  end

  test "取消の URL を直接開くと、休暇の詳細に戻り、取り消されない" do
    leave = leave!
    sign_in_as @admin

    get admin_approval_request_cancellation_path(leave)
    assert_redirected_to admin_approval_request_path(leave)
    assert_response :see_other
    assert leave.reload.effective?
  end

  # ---- 権限 ----

  test "従業員ロールは、URL を直接開いても送信しても取り消せない（ホームに戻され、休暇は承認済みのまま）" do
    own = leave!
    others = leave!(user: @admin, from: d(30), to: d(30))
    sign_in_as @employee

    [ own, others ].each do |leave|
      get admin_approval_request_path(leave)
      assert_redirected_to root_path
      get admin_approval_request_cancellation_path(leave)
      assert_redirected_to root_path

      post_cancel(leave)
      assert_redirected_to root_path
      assert_equal "この画面を表示する権限がありません。", flash[:alert]
      assert leave.reload.effective?
      assert_nil leave.cancelled_by_id
    end
  end

  test "ログインしていなければ取り消せない" do
    leave = leave!
    post_cancel(leave)
    assert_redirected_to login_path
    assert leave.reload.effective?
  end

  # ---- 自己取消（F8 の自己承認ルールと同じ） ----

  test "有効な管理者が2人以上なら、自分の休暇には取消の操作が出ず、案内が出る。直接送っても拒否される" do
    second_admin
    own = leave!(user: @admin)
    sign_in_as @admin

    get admin_approval_request_path(own)
    assert_select "[data-testid='self-cancellation-notice']", text: /ご自身の休暇は他の管理者が取り消します/
    assert_select "[data-testid='self-cancellation-notice']", text: /有効な管理者が2名いるため/
    assert_select "[data-testid='direct-cancellation-form']", 0

    post_cancel(own)
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /ご自身の休暇は他の管理者が取り消します/
    assert own.reload.effective?
  end

  test "有効な管理者が1人だけなら、自分の休暇を取り消せることが表示され、取り消せる" do
    own = leave!(user: @admin)
    sign_in_as @admin

    get admin_approval_request_path(own)
    assert_select "[data-testid='self-cancellation-notice']", text: /管理者が1名のため、ご自身の休暇を取り消せます/
    assert_select "[data-testid='direct-cancellation-form']", 1

    post_cancel(own)
    assert_redirected_to admin_approval_request_path(own)
    assert_equal @admin, own.reload.cancelled_by
  end

  test "2人目の有効な管理者を追加すると、自分の休暇を取り消せなくなる" do
    own = leave!(user: @admin)
    sign_in_as @admin
    get admin_approval_request_path(own)
    assert_select "[data-testid='direct-cancellation-form']", 1

    second_admin
    get admin_approval_request_path(own)
    assert_select "[data-testid='direct-cancellation-form']", 0
    assert_select "[data-testid='self-cancellation-notice']", text: /ご自身の休暇は他の管理者が取り消します/
  end

  test "管理者が自分の休暇を本人画面で開くと、承認画面へのリンクが出る（従業員には出ない）" do
    own = leave!(user: @admin, from: d(24), to: d(24))
    sign_in_as @admin
    get approval_request_path(own)
    assert_select "[data-testid='admin-leave-link'][href='#{admin_approval_request_path(own)}']"

    leave = leave!(from: d(24), to: d(24))
    switch_to @employee
    get approval_request_path(leave)
    assert_select "[data-testid='admin-leave-link']", 0
  end

  # ---- 承認待ちの取消申請との関係 ----

  test "承認待ちの取消申請がある休暇を直接取り消すと、取消申請は承認待ち一覧から消え、取消済みと分かる表示になる" do
    leave = leave!
    request = cancellation!(leave)
    sign_in_as @admin

    get admin_approval_request_path(leave)
    assert_select "[data-testid='direct-cancellation-pending-request']", text: /承認待ちの取消申請があります/
    get admin_approval_requests_path
    assert_select "##{ActionView::RecordIdentifier.dom_id(request)}", 1

    post_cancel(leave)
    assert_match(/承認待ちだった取消申請も、処理済みにしました。/, flash[:notice])

    get admin_approval_requests_path
    assert_select "##{ActionView::RecordIdentifier.dom_id(request)}", 0
    assert_select "[data-testid='approval-badge']", 0

    get admin_approval_requests_path(status: "processed")
    assert_select "##{ActionView::RecordIdentifier.dom_id(request)}" do
      assert_select "[data-testid='closed-by-direct-cancellation']", text: "直接取消で処理済み"
      assert_select "[data-column=reviewer]", text: /管理 太郎/
    end

    get admin_approval_request_path(request)
    assert_select "[data-testid='review-comment']", text: "管理 太郎 さんが休暇を直接取り消したため、この取消申請は処理済みになりました。"
    assert_select "[data-testid='review-form']", 0
    assert_select "[data-testid='leave-details'] [data-testid='leave-cancelled']", text: "取消済み"

    # 処理済みになった取消申請を承認しようとしても、二重に処理されない
    post admin_approval_request_review_path(request), params: { approval_review: { decision: "approve" } }
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /すでに.*処理済み/
    assert_equal "本人から電話で依頼があったため", leave.reload.cancellation_reason

    # 本人の取消申請の画面
    switch_to @employee
    get approval_request_path(request)
    assert_select "[data-testid='processed-note']", text: /管理者が休暇を直接取り消したため、この取消申請は処理済みになりました/
    get leave_requests_path(status: "all")
    assert_select "[data-testid='leave-cancellation-pending']", 0
  end

  test "取消申請が先に承認された休暇は、直接取消の操作が出ず、送っても二重に取り消されない" do
    leave = leave!
    request = cancellation!(leave)
    sign_in_as @admin
    post admin_approval_request_review_path(request), params: { approval_review: { decision: "approve" } }
    cancelled_at = leave.reload.cancelled_at

    get admin_approval_request_path(leave)
    assert_select "[data-testid='direct-cancellation-form']", 0
    assert_select "[data-testid='direct-cancellation-done']", text: /取消申請の承認で/

    travel 1.minute do
      post_cancel(leave)
    end
    assert_response :unprocessable_entity
    assert_equal cancelled_at, leave.reload.cancelled_at
    assert_nil leave.cancelled_by_id
  end

  # ---- 締め済みの月度（F14 で判定を差し込む） ----

  test "締め済みの月度にかかる休暇には取消の操作が出ず、送ってもエラーになり、休暇は承認済みのまま" do
    leave = leave!(from: d(24), to: d(24))
    sign_in_as @admin

    ClosedPeriodGuard.stub(:closed_period_label, ->(_from, _to) { "2026年11月度" }) do
      get admin_approval_request_path(leave)
      assert_select "[data-testid='direct-cancellation-form']", 0
      assert_select "[data-testid='direct-cancellation-blockers']", text: /締め済みの月度（2026年11月度）にかかるため、取り消せません/

      post_cancel(leave)
      assert_response :unprocessable_entity
      assert_select ".flash--alert", text: /締め済みの月度（2026年11月度）/
    end
    assert leave.reload.effective?
  end

  # ---- 従業員向けの案内 ----

  test "従業員の当日・過去の承認済み休暇には、取消申請の操作の代わりに「取消は管理者に依頼してください」と出る" do
    today = leave!(from: d(24), to: d(24))
    past = leave!(from: d(16), to: d(17))
    future = leave!(from: d(26), to: d(26))
    sign_in_as @employee

    [ today, past ].each do |leave|
      get approval_request_path(leave)
      assert_select "[data-testid='cancellation-form']", 0
      assert_select "[data-testid='cancellation-unavailable']", text: /取消は管理者に依頼してください/
    end
    get approval_request_path(future)
    assert_select "[data-testid='cancellation-form']", 1
    assert_select "[data-testid='cancellation-unavailable']", 0
  end

  # ---- スプリント9.1の評価の指摘 ----

  test "取消の注意文は、開始日が今日なら「今日が開始日」、過去なら「開始日を過ぎています」、未来なら出さない" do
    sign_in_as @admin

    get admin_approval_request_path(leave!(from: d(24), to: d(24)))
    assert_select "[data-testid='direct-cancellation-started-note']", text: /この休暇は今日が開始日です/
    assert_select "[data-testid='direct-cancellation-section']", text: /開始日を過ぎています/, count: 0

    get admin_approval_request_path(leave!(from: d(16), to: d(17)))
    assert_select "[data-testid='direct-cancellation-started-note']", text: /この休暇は開始日を過ぎています/

    get admin_approval_request_path(leave!(from: d(26), to: d(26)))
    assert_select "[data-testid='direct-cancellation-started-note']", 0
  end

  test "処理済み一覧の「結果」「処理した管理者」「処理日時」欄は、中身を1つのまとまりにする（375px のカード表示で崩れない）" do
    leave = leave!(from: d(24), to: d(24))
    sign_in_as @admin
    post_cancel(leave)

    get admin_approval_requests_path(status: "processed")
    assert_select "##{ActionView::RecordIdentifier.dom_id(leave)}" do
      assert_select "td[data-column=status] > div.approvals-table__cell > [data-testid='direct-cancellation-reason']"
      assert_select "td[data-column=status] > div.approvals-table__cell > [data-testid='leave-cancelled']"
      assert_select "td[data-column=reviewer] > div.approvals-table__cell > [data-testid='direct-cancellation-by']"
      assert_select "td[data-column=reviewed-at] > div.approvals-table__cell > [data-testid='direct-cancellation-at']"
    end
  end
end
