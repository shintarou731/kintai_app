require "test_helper"

class LeaveRequestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-24 は火曜日
  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @employee = users(:employee)
    @admin = users(:admin)
    travel_to NOW
    sign_in_as @employee
  end

  teardown { travel_back }

  def d(day, month: 11)
    Date.new(2026, month, day)
  end

  def leave!(user: @employee, from: d(26), to: d(27), type: "paid", part: "full_day", status: "pending")
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: part, reason: "私用のため")
    assert leave.submit, leave.errors.full_messages.inspect
    leave.update_columns(status: status, reviewer_id: @admin.id, reviewed_at: NOW) unless status == "pending"
    leave
  end

  def post_leave(**fields)
    params = { leave_type: "paid", target_date: "2026-11-26", end_date: "2026-11-27", day_part: "full_day", reason: "私用のため" }
    post leave_requests_path, params: { leave_request: params.merge(fields) }
  end

  # ---- 画面 ----

  test "ナビに「休暇」があり、休暇画面に申請フォームと自分の休暇の一覧が出る" do
    leave!(from: d(26), to: d(27))
    leave!(from: d(30), to: d(30), status: "approved")
    leave!(user: @admin, from: d(26), to: d(26))

    get leave_requests_path
    assert_response :success
    assert_select "[data-testid='nav-leaves'][aria-current='page']", text: "休暇"
    assert_select "[data-testid='leave-form']" do
      assert_select "input[type=radio][name='leave_request[leave_type]']", 3
      assert_select "input[type=radio][name='leave_request[leave_type]'][value=paid][checked]"
      assert_select "input[type=radio][name='leave_request[day_part]']", 3
      assert_select "input[type=date][name='leave_request[target_date]'][value='2026-11-24']"
      assert_select "textarea[name='leave_request[reason]']"
    end
    assert_select "[data-testid='leave-row']", 2
    assert_select "[data-testid='leave-row']:first-of-type" do
      assert_select "[data-column=period]", text: "11/26(木)〜11/27(金)"
      assert_select "[data-column=leave-type]", text: "有給休暇"
      assert_select "[data-column=day-part]", text: "全日"
      assert_select "[data-column=days]", text: "2日"
      assert_select "[data-testid=request-status]", text: "承認待ち"
    end
  end

  test "終了日が過ぎた休暇は「すべて」に出る" do
    leave!(from: d(16), to: d(17), type: "absence")

    get leave_requests_path
    assert_select "[data-testid='leave-row']", 0
    assert_select "[data-testid='leaves-empty']", text: "これからの休暇はありません。"
    get leave_requests_path(status: "all")
    assert_select "[data-testid='leave-row']", 1
  end

  test "（スプリント9の指摘）「これからの休暇」には承認待ち・有効な承認済みだけが出て、取り下げ・却下・取消済みは「すべて」にだけ出る" do
    pending = leave!(from: d(26), to: d(26))
    approved = leave!(from: d(27), to: d(27), status: "approved")
    leave!(from: d(30), to: d(30), status: "withdrawn")
    leave!(from: d(1, month: 12), to: d(1, month: 12), status: "rejected")
    leave!(from: d(2, month: 12), to: d(2, month: 12), status: "approved").update_columns(cancelled_at: NOW)

    get leave_requests_path
    assert_select "[data-testid='leave-row']", 2
    assert_select "[data-testid='leave-row'] [data-testid=request-status]" do |statuses|
      assert_equal %w[承認待ち 承認済み], statuses.map { |status| status.text.strip }
    end
    assert_select "a[href='#{approval_request_path(pending)}']"
    assert_select "a[href='#{approval_request_path(approved)}']"
    get leave_requests_path(status: "all")
    assert_select "[data-testid='leave-row']", 5
  end

  test "休暇を申請すると承認待ちになり、一覧に戻ってメッセージが出る" do
    assert_difference -> { LeaveRequest.count }, 1 do
      post_leave(leave_type: "special", target_date: "2026-11-26", end_date: "2026-11-30")
    end
    leave = LeaveRequest.last
    assert_redirected_to leave_requests_path
    assert_equal "11/26(木)〜11/30(月) の特別休暇（全日）を申請しました（承認待ち）。承認されると勤怠履歴に表示されます。", flash[:notice]
    assert leave.pending?
    assert_equal [ d(26), d(30) ], [ leave.target_date, leave.end_date ]

    follow_redirect!
    assert_select "tr#leave_request_#{leave.id}.is-highlighted [data-column=days]", text: "3日・土日祝を除く"
  end

  test "半休は1日だけ申請でき、2日以上の期間は 422 でエラーが上部と入力欄に出る" do
    post_leave(day_part: "morning", target_date: "2026-11-26", end_date: "2026-11-26")
    assert_redirected_to leave_requests_path
    assert LeaveRequest.last.morning?

    assert_no_difference -> { LeaveRequest.count } do
      post_leave(day_part: "afternoon", target_date: "2026-11-30", end_date: "2026-12-01")
    end
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: "休暇を申請できませんでした。入力内容を確認してください。"
    assert_select ".form-errors li", text: "区分が半休のときは、1日だけ指定できます（開始日と終了日を同じ日にしてください）"
    # 入力した内容は残る
    assert_select "input[name='leave_request[day_part]'][value=afternoon][checked]"
    assert_select "input[name='leave_request[end_date]'][value='2026-12-01']"
  end

  test "終了日が開始日より前・重なる期間・種類なしは申請できない" do
    post_leave(target_date: "2026-11-27", end_date: "2026-11-26")
    assert_response :unprocessable_entity
    assert_select ".form-errors li", text: "終了日は開始日と同じか、開始日より後の日付にしてください"

    leave!(from: d(26), to: d(27), status: "approved")
    post_leave(target_date: "2026-11-27", end_date: "2026-11-30")
    assert_response :unprocessable_entity
    assert_select ".form-errors li", text: /11\/26\(木\)〜11\/27\(金\) の有給休暇（全日）（承認済み）と期間が重なっています/

    post_leave(leave_type: "", target_date: "2026-12-07", end_date: "2026-12-07")
    assert_response :unprocessable_entity
    assert_select ".form-errors li", text: "休暇の種類を「有給休暇」「特別休暇」「欠勤」から選んでください"
  end

  test "パラメーターが欠けていても 400 にならず、エラーを出す" do
    post leave_requests_path, params: {}
    assert_response :unprocessable_entity
    assert_select ".form-errors"
  end

  test "過去の日付の休暇（欠勤など）も申請できる" do
    post_leave(leave_type: "absence", target_date: "2026-11-20", end_date: "2026-11-20", reason: "体調不良で欠勤しました")
    assert_redirected_to leave_requests_path
    assert LeaveRequest.last.leave_absence?
  end

  test "ログインしていないと休暇画面を開けない" do
    delete logout_path
    get leave_requests_path
    assert_redirected_to login_path
  end

  # ---- 休暇の詳細（申請の詳細）・取り下げ ----

  test "承認待ちの休暇の詳細に内容と取り下げボタンが出て、取り下げられる" do
    leave = leave!(from: d(26), to: d(27))

    get approval_request_path(leave)
    assert_response :success
    assert_select "h1", text: /休暇申請.*2026年11月26日\(木\)〜11月27日\(金\)/
    assert_select "[data-testid='leave-type']", text: "有給休暇"
    assert_select "[data-testid='leave-days']", text: /2日/
    assert_select "[data-testid='withdraw-button']"
    assert_select "[data-testid='cancellation-form']", 0

    post approval_request_withdrawal_path(leave)
    assert_redirected_to approval_request_path(leave)
    assert_equal "11/26(木)〜11/27(金) の休暇申請を取り下げました。休暇は登録されません。", flash[:notice]
    assert leave.reload.withdrawn?
  end

  test "申請一覧にも休暇申請が種類「休暇」・期間・内容つきで並ぶ" do
    leave!(from: d(26), to: d(26), part: "afternoon")

    get approval_requests_path
    assert_select "[data-testid='request-row']" do
      assert_select "[data-column=target-date]", text: "11/26(木)"
      assert_select "[data-column=kind]", text: "休暇"
      assert_select "[data-column=summary]", text: "有給休暇・午後半休（0.5日）"
    end
  end

  # ---- 取消申請 ----

  test "未来の承認済みの休暇には取消申請を出せ、承認待ちの間は休暇が有効のまま" do
    leave = leave!(from: d(26), to: d(27), status: "approved")

    get approval_request_path(leave)
    assert_select "[data-testid='withdraw-button']", 0
    assert_select "[data-testid='cancellation-form']"

    assert_difference -> { LeaveCancellationRequest.count }, 1 do
      post leave_request_cancellation_path(leave), params: { leave_cancellation_request: { reason: "予定が変わったため" } }
    end
    cancel = LeaveCancellationRequest.last
    assert_redirected_to approval_request_path(cancel)
    assert_equal "11/26(木)〜11/27(金) の有給休暇（全日）の取消を申請しました（承認待ち）。承認されるまで休暇は有効です。", flash[:notice]
    assert leave.reload.effective?

    follow_redirect!
    assert_select "h1", text: /休暇取消申請/
    assert_select "[data-testid='leave-details']", text: /取り消す休暇/
    assert_select "[data-testid='withdraw-button']", text: "この取消申請を取り下げる"

    get approval_request_path(leave)
    assert_select "[data-testid='cancellation-pending']", text: /取消申請中です/
    assert_select "[data-testid='cancellation-form']", 0

    get leave_requests_path
    assert_select "[data-testid='leave-cancellation-pending']", text: "取消申請中"

    # 取消申請を取り下げても休暇は有効のまま
    post approval_request_withdrawal_path(cancel)
    assert_equal "11/26(木)〜11/27(金) の休暇取消申請を取り下げました。休暇は有効のままです。", flash[:notice]
    assert leave.reload.effective?
  end

  test "取消申請の理由が空なら 422 で、詳細画面の上部と入力欄にエラーが出る" do
    leave = leave!(from: d(26), to: d(27), status: "approved")

    post leave_request_cancellation_path(leave), params: { leave_cancellation_request: { reason: " " } }
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: "取消申請できませんでした：取消の理由を入力してください"
    assert_select "[data-testid='cancellation-form'] .form-errors li", text: "取消の理由を入力してください"
    assert_equal 0, LeaveCancellationRequest.count

    post leave_request_cancellation_path(leave), params: { leave_cancellation_request: "x" }
    assert_response :unprocessable_entity
  end

  test "当日・過去の承認済みの休暇には取消申請のフォームが出ず、直接送っても拒否される" do
    today = leave!(from: d(24), to: d(24), status: "approved")

    get approval_request_path(today)
    assert_select "[data-testid='cancellation-form']", 0
    assert_select "[data-testid='cancellation-unavailable']", text: /取消は管理者に依頼してください/

    post leave_request_cancellation_path(today), params: { leave_cancellation_request: { reason: "取り消したい" } }
    assert_response :unprocessable_entity
    assert_select ".flash--alert", text: /開始日が今日または過去の休暇は、取消申請できません。取消は管理者に依頼してください/
    assert_equal 0, LeaveCancellationRequest.count
  end

  test "他の人の休暇や存在しない休暇には取消申請できない" do
    others = leave!(user: @admin, from: d(26), to: d(26), status: "approved")

    post leave_request_cancellation_path(others), params: { leave_cancellation_request: { reason: "x" } }
    assert_redirected_to approval_requests_path
    assert_equal "指定された申請が見つかりません。一覧から選び直してください。", flash[:alert]
    post leave_request_cancellation_path(99_999), params: { leave_cancellation_request: { reason: "x" } }
    assert_redirected_to approval_requests_path
    assert_equal 0, LeaveCancellationRequest.count
  end

  test "（スプリント9の指摘）取消申請の URL を直接開くと、エラー画面ではなく休暇の詳細へ戻る" do
    leave = leave!(from: d(26), to: d(27), status: "approved")
    others = leave!(user: @admin, from: d(26), to: d(26), status: "approved")

    get leave_request_cancellation_path(leave)
    assert_redirected_to approval_request_path(leave)
    get leave_request_cancellation_path(others)
    assert_redirected_to approval_requests_path
    assert_equal "指定された申請が見つかりません。一覧から選び直してください。", flash[:alert]
    get leave_request_cancellation_path(99_999)
    assert_redirected_to approval_requests_path
    assert_equal 0, LeaveCancellationRequest.count
  end

  test "取り消された休暇の詳細には取消済みと出て、取消申請のフォームは出ない" do
    leave = leave!(from: d(26), to: d(27), status: "approved")
    leave.update_columns(cancelled_at: NOW)

    get approval_request_path(leave)
    assert_select "[data-testid='leave-cancelled']", text: "取消済み"
    assert_select "[data-testid='processed-note']", text: /取り消されました/
    assert_select "[data-testid='cancellation-form']", 0
  end

  # ---- 祝日（スプリント9.2） ----

  test "祝日を含む休暇は休日を除いて数える：11/20(金)〜11/24(火)は「2日」。一覧・詳細・勤怠履歴の合計がそろう" do
    post_leave(target_date: "2026-11-20", end_date: "2026-11-24")
    leave = LeaveRequest.last
    assert_redirected_to leave_requests_path
    assert_equal 2, leave.chargeable_days

    get leave_requests_path(status: "all")
    assert_select "tr#leave_request_#{leave.id} [data-column=days]", text: "2日・土日祝を除く"
    assert_select ".form__hint", text: /日数は休日（土日・祝日）を除いて数えます/

    get approval_request_path(leave)
    assert_select "[data-testid='leave-days']", text: /2日/
    assert_select "[data-testid='leave-days']", text: /休日（土日・祝日）を除いて数えます/
    assert_select "[data-testid='leave-days-off']", text: "除いた休日：11/21(土)、11/22(日)、11/23(月) 勤労感謝の日"
    assert_select "[data-testid='leave-period']", text: /（5日間）/

    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    get attendances_path(month: "2026-11")
    assert_select "[data-testid='leave-totals']", text: /有給 2日/
    assert_select "[data-testid='leave-totals']", text: /土日・祝日は数えません/
  end

  test "休日（土日・祝日）だけの期間の有給休暇は申請できない（11/21(土)〜11/23(勤労感謝の日)）" do
    post_leave(target_date: "2026-11-21", end_date: "2026-11-23")
    assert_response :unprocessable_entity
    assert_select ".form-errors li", text: /有給休暇は休日（土日・祝日）を日数に数えないため、休日だけの期間は申請できません/
    assert_equal 0, LeaveRequest.count

    # 祝日1日だけ（平日の勤労感謝の日）の有給も申請できない。特別休暇なら申請できる
    post_leave(target_date: "2026-11-23", end_date: "2026-11-23")
    assert_response :unprocessable_entity
    post_leave(leave_type: "special", target_date: "2026-11-23", end_date: "2026-11-23")
    assert_redirected_to leave_requests_path
    assert LeaveRequest.last.leave_special?
  end

  test "休暇の入力画面に、日数の表示に使う祝日（前後1年）が渡される" do
    get leave_requests_path
    form = css_select("[data-testid='leave-form']").first
    holidays = JSON.parse(form["data-leave-form-holidays-value"])
    assert_equal "勤労感謝の日", holidays["2026-11-23"]
    assert_equal "元日", holidays["2027-01-01"]
  end

  test "取り消した休暇の詳細では、勤怠履歴での表示は灰色の打ち消し線で「表示されません（取消済み）」と出る" do
    leave = leave!(from: d(26), to: d(26), status: "approved")
    leave.update_columns(cancelled_at: NOW)

    get approval_request_path(leave)
    assert_select "[data-testid='leave-history-display'] .badge--leave-off", text: "有給（全日）"
    assert_select "[data-testid='leave-history-display'] .badge--leave", 0
    assert_select "[data-testid='leave-history-hidden']", text: "表示されません（取消済み）"

    effective = leave!(from: d(30), to: d(30), status: "approved")
    get approval_request_path(effective)
    assert_select "[data-testid='leave-history-display'] .badge--leave", text: "有給（全日）"
    assert_select "[data-testid='leave-history-hidden']", 0

    pending = leave!(from: d(27), to: d(27))
    get approval_request_path(pending)
    assert_select "[data-testid='leave-history-display'] .badge--leave-pending", text: "有給（全日）・申請中"
  end
end
