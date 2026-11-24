require "test_helper"
require "minitest/mock"

class Admin::ApprovalRequestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @admin = users(:admin)
    @employee = users(:employee)
  end

  def t(day, hour, min = 0)
    Time.zone.local(2026, 11, day, hour, min)
  end

  def correction(user: @employee, date: Date.new(2026, 11, 20), clock_in: "09:00", clock_out: "18:00", breaks: [], at: NOW - 1.day)
    request = user.attendance_correction_requests.new(
      target_date: date, clock_in_time: clock_in, clock_out_time: clock_out, reason: "打刻を忘れました\n18:00 に退勤しています",
      break_inputs: breaks.each_with_index.to_h { |(start, finish), index| [ index.to_s, { start_time: start, end_time: finish } ] }
    )
    travel_to(at) { assert request.submit, request.errors.full_messages.inspect }
    request
  end

  def second_admin(active: true)
    User.create!(name: "管理 二郎", email: "admin2@example.com", password: "password123", role: "admin", active: active,
                 hired_on: Date.new(2021, 4, 1))
  end

  def post_review(request, decision:, comment: nil)
    post admin_approval_request_review_path(request), params: { approval_review: { decision: decision, comment: comment } }
  end

  def dom(record)
    "##{ActionView::RecordIdentifier.dom_id(record)}"
  end

  # ログイン中は再ログインできないので、ログアウトしてから別のユーザーでログインする
  def switch_to(user)
    delete logout_path
    sign_in_as user
  end

  # ---- 権限 ----

  test "従業員は承認画面を開けず、承認・却下も送れない" do
    request = correction
    travel_to NOW do
      sign_in_as @employee
      get admin_approval_requests_path
      assert_redirected_to root_path
      assert_equal "この画面を表示する権限がありません。", flash[:alert]
      get admin_approval_request_path(request)
      assert_redirected_to root_path
      post_review(request, decision: "approve")
      assert_redirected_to root_path
      assert request.reload.pending?

      get root_path
      assert_select "[data-testid='nav-approvals']", 0
    end
  end

  # ---- 一覧とバッジ ----

  test "承認待ちの一覧（申請者・種類・対象日・申請日）と、ナビの「承認」に件数のバッジ" do
    older = correction(date: Date.new(2026, 11, 18), at: t(19, 9))
    newer = correction(user: users(:inactive_employee).tap { |user| user.update_column(:active, true) },
                       date: Date.new(2026, 11, 20), at: t(21, 9))
    withdrawn = correction(date: Date.new(2026, 11, 17))
    withdrawn.withdraw

    travel_to NOW do
      sign_in_as @admin
      get admin_approval_requests_path
      assert_response :success
      assert_select ".header__nav [data-testid='nav-approvals'][href='#{admin_approval_requests_path}']", /承認/
      assert_select "[data-testid='approval-badge']", /\A2/
      assert_select "[data-testid='admin-menu-badge']", "2"
      assert_select "[data-testid='nav-approvals'].is-active[aria-current='page']"

      assert_select "thead th", /申請者|種類|対象日|申請日/
      assert_select "[data-testid='approval-row']", 2
      # 古い申請から順に並ぶ
      assert_select "[data-testid='approval-row']:first-child#{dom(older)}"
      assert_select "#{dom(older)} td[data-column='applicant']", /従業 花子/
      assert_select "#{dom(older)} td[data-column='kind']", "打刻修正"
      assert_select "#{dom(older)} td[data-column='target-date']", "11/18(水)"
      assert_select "#{dom(older)} td[data-column='submitted-at']", "11/19 09:00"
      assert_select "#{dom(older)} td[data-column='summary']", "出勤 09:00／退勤 18:00／休憩 0回"
      assert_select "#{dom(older)} a[href='#{admin_approval_request_path(older)}']", "確認する"
      assert_select "#{dom(newer)} td[data-column='applicant']", /退職 次郎/
      assert_select dom(withdrawn), 0
      assert_select "[data-testid='filter-pending'] .tabs__count", "2"
      assert_select "[data-testid='filter-processed'] .tabs__count", "0"
    end
  end

  test "承認待ちが無ければバッジは出ず、空の案内が出る" do
    travel_to NOW do
      sign_in_as @admin
      get admin_approval_requests_path
      assert_select "[data-testid='approval-badge']", 0
      assert_select "[data-testid='admin-menu-badge']", 0
      assert_select "[data-testid='approvals-empty']", /承認待ちの申請はありません/
    end
  end

  test "「処理済み」に切り替えると、結果・処理した管理者・処理日時が新しい順に出る" do
    approved = correction(date: Date.new(2026, 11, 18))
    rejected = correction(date: Date.new(2026, 11, 19))
    travel_to(t(24, 9)) { assert ApprovalReview.new(approval_request: approved, reviewer: @admin, decision: "approve").save }
    travel_to(t(24, 10)) do
      assert ApprovalReview.new(approval_request: rejected, reviewer: @admin, decision: "reject", comment: "違います").save
    end
    pending = correction(date: Date.new(2026, 11, 20))

    travel_to NOW do
      sign_in_as @admin
      get admin_approval_requests_path(status: "processed")
      assert_response :success
      assert_select "[data-testid='filter-processed'].is-active"
      assert_select "[data-testid='approval-row']", 2
      assert_select "[data-testid='approval-row']:first-child#{dom(rejected)}"
      assert_select "#{dom(rejected)} td[data-column='status']", "却下"
      assert_select "#{dom(approved)} td[data-column='status']", "承認済み"
      assert_select "#{dom(approved)} td[data-column='reviewer']", @admin.name
      assert_select "#{dom(approved)} td[data-column='reviewed-at']", "11/24 09:00"
      assert_select "#{dom(approved)} a", "詳細"
      assert_select dom(pending), 0
      assert_select "[data-testid='approval-badge']", /\A1/
    end
  end

  # ---- 詳細 ----

  test "打刻修正申請の詳細：今の記録と申請内容を並べ、変わる箇所に印が付く" do
    travel_to(t(20, 13)) do # 申請より前に記録された勤怠
      @employee.attendances.create!(work_date: Date.new(2026, 11, 20), clock_in_at: t(20, 9)).tap do |attendance|
        attendance.breaks.create!(started_at: t(20, 12), ended_at: t(20, 13))
      end
    end
    request = correction(breaks: [ [ "12:00", "13:00" ] ])

    travel_to NOW do
      sign_in_as @admin
      get admin_approval_request_path(request)
      assert_response :success
      assert_select "h1", /打刻修正申請/
      assert_select "[data-testid='applicant']", /従業 花子/
      assert_select "[data-testid='comparison-base-label']", "今の記録"
      assert_select "[data-testid='correction-comparison'] tr[data-item='出勤']:not(.is-changed) td[data-column='current']", "09:00"
      assert_select "[data-testid='correction-comparison'] tr[data-item='退勤'].is-changed td[data-column='current']", "未打刻"
      assert_select "[data-testid='correction-comparison'] tr[data-item='退勤'].is-changed td[data-column='requested']", "18:00"
      assert_select "[data-testid='correction-comparison'] tr[data-item='退勤'] .badge", "変更"
      assert_select "[data-testid='correction-comparison'] tr[data-item='休憩']:not(.is-changed)"
      assert_select "[data-testid='correction-comparison'] tr[data-item='実働時間'].is-changed td[data-column='requested']", "8:00"
      assert_select "[data-testid='request-reason']", /18:00 に退勤しています/
      assert_select "[data-testid='review-form'][action='#{admin_approval_request_review_path(request)}']"
      assert_select "[data-testid='review-form'] textarea[name='approval_review[comment]'][maxlength='500']"
      assert_select "[data-testid='approve-button'][name='approval_review[decision]'][value='approve']:not([disabled])"
      assert_select "[data-testid='reject-button'][value='reject']"
      assert_select "[data-testid='self-review-notice']", 0
      assert_select "[data-testid='record-changed-notice']", 0
    end
  end

  test "存在しない申請は一覧に戻す" do
    sign_in_as @admin
    get admin_approval_request_path(9999)
    assert_redirected_to admin_approval_requests_path
    assert_equal "指定された申請が見つかりません。一覧から選び直してください。", flash[:alert]
    post admin_approval_request_review_path(9999), params: { approval_review: { decision: "approve" } }
    assert_redirected_to admin_approval_requests_path
  end

  # ---- 承認・却下 ----

  test "承認すると勤怠記録が申請内容どおりに更新され、一覧に戻ってメッセージが出る" do
    request = correction(breaks: [ [ "12:00", "13:00" ] ])
    travel_to NOW do
      sign_in_as @admin
      post_review(request, decision: "approve", comment: "")
      assert_redirected_to admin_approval_requests_path
      assert_equal "従業 花子 さんの 11/20(金) の打刻修正申請を承認しました。勤怠記録を申請内容どおりに更新しました。", flash[:notice]
    end
    request.reload
    assert request.approved?
    assert_equal @admin, request.reviewer
    assert_nil request.review_comment
    attendance = @employee.attendances.find_by!(work_date: Date.new(2026, 11, 20))
    assert_equal [ t(20, 9), t(20, 18) ], [ attendance.clock_in_at, attendance.clock_out_at ]
    assert_equal 1, attendance.breaks.count

    # 従業員の勤怠履歴に反映され、「申請中」の印は消える
    travel_to NOW do
      switch_to @employee
      get attendances_path(month: "2026-11")
      assert_select "tr[data-date='2026-11-20'] [data-testid='pending-correction']", 0
      assert_select "tr[data-date='2026-11-20']", /18:00/
      assert_select "tr[data-date='2026-11-20'] td", "8:00"
    end
  end

  test "却下はコメントが必須（空なら 422 で詳細を再表示し、承認待ちのまま）。却下しても勤怠は変わらない" do
    request = correction
    travel_to NOW do
      sign_in_as @admin
      post_review(request, decision: "reject", comment: "")
      assert_response :unprocessable_entity
      assert_select ".form-errors", /コメントを入力してください（却下するときは、理由をコメントに書いてください）/
      assert request.reload.pending?

      post_review(request, decision: "reject", comment: "退勤時刻がタイムカードと違います。\n確認して出し直してください。")
      assert_redirected_to admin_approval_requests_path
      assert_equal "従業 花子 さんの 11/20(金) の打刻修正申請を却下しました。勤怠記録は変わりません。", flash[:notice]
    end
    assert request.reload.rejected?
    assert_equal 0, Attendance.count
  end

  test "承認・却下の結果とコメントは申請者の「申請」画面に出て、処理済みの申請は取り下げできない" do
    request = correction
    travel_to(NOW) do
      assert ApprovalReview.new(approval_request: request, reviewer: @admin, decision: "reject", comment: "違います。\n出し直してください").save
    end

    travel_to NOW + 1.hour do
      sign_in_as @employee
      get approval_requests_path
      assert_select "#{dom(request)} td[data-column='status']", /却下/
      assert_select "#{dom(request)} [data-testid='request-review']", /#{@admin.name}（11\/24 10:30）/
      assert_select "#{dom(request)} [data-testid='request-review']", /コメント：違います。 出し直してください/
      get approval_requests_path(status: "processed")
      assert_select "[data-testid='request-row']", 1

      get approval_request_path(request)
      assert_select "[data-testid='review-result']", /却下/
      assert_select "[data-testid='reviewer-name']", @admin.name
      assert_select "[data-testid='reviewed-at']", "2026年11月24日(火) 10:30"
      assert_select "[data-testid='review-comment'].request-reason", /\A違います。\s+出し直してください\z/
      assert_select "[data-testid='comparison-base-label']", "却下時の記録"
      assert_select "[data-testid='withdraw-button']", 0
      assert_select "[data-testid='processed-note']", /処理済みの申請は取り下げできません/
      assert_select "a[href=?]", new_attendance_correction_request_path(date: "2026-11-20"), "この日の修正申請を出し直す"

      post approval_request_withdrawal_path(request)
      assert_redirected_to approval_request_path(request)
      assert_match "「却下」のため、取り下げできません", flash[:alert]
      assert request.reload.rejected?
    end
  end

  test "承認済みの申請は、申請者の画面で「承認前の記録」と申請内容を比べられ、取り下げできない" do
    request = correction
    travel_to(NOW) { assert ApprovalReview.new(approval_request: request, reviewer: @admin, decision: "approve").save }
    travel_to NOW + 1.hour do
      sign_in_as @employee
      get approval_request_path(request)
      assert_select "[data-testid='comparison-base-label']", "承認前の記録"
      assert_select "[data-testid='correction-comparison'] tr[data-item='出勤'].is-changed td[data-column='current']", "未打刻"
      assert_select "[data-testid='review-comment']", "（コメントなし）"
      assert_select "[data-testid='withdraw-button']", 0
      post approval_request_withdrawal_path(request)
      assert_match "「承認済み」のため、取り下げできません", flash[:alert]
      assert request.reload.approved?
    end
  end

  test "二重承認：処理済みの申請に送ると、422 で詳細と「処理済み」が出て、勤怠は1回分だけ" do
    request = correction
    travel_to NOW do
      sign_in_as @admin
      post_review(request, decision: "approve")
      post_review(request, decision: "approve")
      assert_response :unprocessable_entity
      assert_select ".form-errors", /すでに#{@admin.name} さんが 11\/24 10:30 に処理済みです（承認済み）/
      assert_select "[data-testid='review-form']", 0
      assert_select "[data-testid='review-unavailable']", /処理済み/
      post_review(request, decision: "reject", comment: "やはり却下")
      assert_response :unprocessable_entity
    end
    assert request.reload.approved?
    assert_equal 1, Attendance.count
  end

  test "取り下げられた申請は承認できない" do
    request = correction
    request.withdraw
    travel_to NOW do
      sign_in_as @admin
      post_review(request, decision: "approve")
      assert_response :unprocessable_entity
      assert_select ".form-errors", /申請者が取り下げたため/
    end
    assert request.reload.withdrawn?
    assert_equal 0, Attendance.count
  end

  test "承認時に前日・翌日の勤務と重なるなら、理由を表示して承認ボタンを無効にし、直接送っても承認されない" do
    request = correction(date: Date.new(2026, 11, 20), clock_out: "10:00") # 退勤 10:00（申請は 18:00 → 10:00 に変更）
    request.update_columns(requested_clock_in_at: t(20, 22), requested_clock_out_at: t(21, 10))
    @employee.attendances.create!(work_date: Date.new(2026, 11, 21), clock_in_at: t(21, 9), clock_out_at: t(21, 18))

    travel_to NOW do
      sign_in_as @admin
      get admin_approval_request_path(request)
      assert_select "[data-testid='approval-blockers']", /翌日（11\/21\(土\)）の勤務の出勤（09:00）より後に退勤する内容のため承認できません/
      assert_select "[data-testid='approve-button'][disabled]"
      assert_select "[data-testid='reject-button']:not([disabled])"

      post_review(request, decision: "approve")
      assert_response :unprocessable_entity
      assert_select ".form-errors", /翌日の勤務と重なります/
      assert_select "[data-testid='approval-blockers']", 0, "エラーと同じ内容を二重に出さない"
    end
    assert request.reload.pending?
    assert_not @employee.attendances.exists?(work_date: Date.new(2026, 11, 20))
  end

  test "パラメーターが欠けた送信は 400 にせず、詳細にエラーを出す" do
    request = correction
    travel_to NOW do
      sign_in_as @admin
      post admin_approval_request_review_path(request)
      assert_response :unprocessable_entity
      assert_select ".form-errors", /操作は「承認する」か「却下する」を選んでください/
      post admin_approval_request_review_path(request), params: { approval_review: "abc" }
      assert_response :unprocessable_entity
    end
    assert request.reload.pending?
  end

  test "ロック競合のときは 500 にせず、詳細にメッセージを出す" do
    request = correction
    busy = begin
      raise SQLite3::BusyException, "database is locked"
    rescue SQLite3::BusyException
      begin
        raise ActiveRecord::StatementInvalid, "SQLite3::BusyException: database is locked"
      rescue ActiveRecord::StatementInvalid => error
        error
      end
    end
    travel_to NOW do
      sign_in_as @admin
      ApprovalRequest.stub(:lock, -> { raise busy }) do
        post_review(request, decision: "approve")
      end
      assert_response :unprocessable_entity
      assert_select ".form-errors", /他の操作と同時に処理されたため、完了できませんでした/

      # 取り下げなど、モデルで捕まえていない書き込みも、元の画面に戻してメッセージを出す
      switch_to @employee
      ApprovalRequest.stub(:where, ->(*) { raise busy }) do
        post approval_request_withdrawal_path(request), headers: { "HTTP_REFERER" => approval_request_url(request) }
      end
      assert_redirected_to approval_request_url(request)
      assert_equal DatabaseLockError::MESSAGE, flash[:alert]
    end
    assert request.reload.pending?
  end

  # ---- 自己承認ルール ----

  test "有効な管理者が1人だけなら、自分の申請の詳細にその旨が出て、自分で承認できる（処理者は本人）" do
    own = correction(user: @admin)
    travel_to NOW do
      sign_in_as @admin
      get admin_approval_requests_path
      assert_select "#{dom(own)} [data-testid='own-request']", "あなたの申請"
      assert_select "#{dom(own)} a", "確認する"
      assert_select "[data-testid='self-review-summary']", /管理者が1名のため/

      get admin_approval_request_path(own)
      assert_select "[data-testid='self-review-notice']", /管理者が1名のため、ご自身の申請を承認・却下できます/
      assert_select "[data-testid='approve-button']:not([disabled])"
      assert_select "[data-testid='reject-button']"

      post_review(own, decision: "approve")
      assert_redirected_to admin_approval_requests_path
    end
    own.reload
    assert own.approved?
    assert_equal @admin, own.reviewer

    travel_to NOW + 1.hour do
      get admin_approval_requests_path(status: "processed")
      assert_select "#{dom(own)} td[data-column='reviewer']", @admin.name
      get approval_request_path(own)
      assert_select "[data-testid='reviewer-name']", @admin.name
    end
  end

  test "有効な管理者が2人以上なら、自分の申請は操作が出ず、直接送っても拒否されて承認待ちのまま" do
    second_admin
    own = correction(user: @admin)
    travel_to NOW do
      sign_in_as @admin
      get admin_approval_requests_path
      assert_select "#{dom(own)} a", "詳細"
      assert_select "[data-testid='self-review-summary']", /他の管理者が処理します/

      get admin_approval_request_path(own)
      assert_select "[data-testid='self-review-notice']", /ご自身の申請は他の管理者が処理します/
      assert_select "[data-testid='review-form']", 0
      assert_select "[data-testid='approve-button']", 0
      assert_select "[data-testid='review-unavailable']", /ご自身の申請のため/

      %w[approve reject].each do |decision|
        post_review(own, decision: decision, comment: "自分で処理")
        assert_response :unprocessable_entity
        assert_select ".form-errors", /ご自身の申請は他の管理者が処理します/
        assert own.reload.pending?
      end
    end
    assert_not @admin.attendances.exists?(work_date: Date.new(2026, 11, 20))

    # もう1人の管理者は処理できる
    travel_to NOW do
      switch_to User.find_by!(email: "admin2@example.com")
      get admin_approval_request_path(own)
      assert_select "[data-testid='self-review-notice']", 0
      post_review(own, decision: "approve")
      assert_redirected_to admin_approval_requests_path
    end
    assert_equal "管理 二郎", own.reload.reviewer.name
  end

  test "有効な管理者の人数が変わると、表示と動作も切り替わる（無効化された管理者は数えない）" do
    other = second_admin(active: false)
    own = correction(user: @admin)
    travel_to NOW do
      sign_in_as @admin
      get admin_approval_request_path(own)
      assert_select "[data-testid='self-review-notice']", /管理者が1名のため/

      # 2人目を有効にする（従業員管理の画面から）
      post admin_employee_activation_path(other)
      assert other.reload.active?
      get admin_approval_request_path(own)
      assert_select "[data-testid='self-review-notice']", /他の管理者が処理します/
      post_review(own, decision: "approve")
      assert_response :unprocessable_entity
      assert own.reload.pending?

      # 2人目を無効に戻すと、また自分で処理できる
      delete admin_employee_activation_path(other)
      assert_not other.reload.active?
      get admin_approval_request_path(own)
      assert_select "[data-testid='self-review-notice']", /管理者が1名のため/
      post_review(own, decision: "reject", comment: "自分で却下")
      assert_redirected_to admin_approval_requests_path
    end
    assert own.reload.rejected?
    assert_equal @admin, own.reviewer
  end

  # ---- 退勤が空欄の申請・申請後の記録の変化 ----

  test "退勤が空欄の申請と、申請後に記録が変わった申請には、詳細で注意が出る" do
    correction_request = correction(date: Date.new(2026, 11, 24), clock_in: "08:00", clock_out: "", at: t(24, 9))
    # 申請した後に、ホームで出勤を打刻した
    travel_to(t(24, 9, 5)) { @employee.attendances.create!(work_date: Date.new(2026, 11, 24), clock_in_at: t(24, 9, 5)) }

    travel_to t(24, 9, 30) do
      sign_in_as @admin
      get admin_approval_request_path(correction_request)
      assert_select "[data-testid='open-ended-notice']", /退勤は未打刻のまま（勤務中）になります/
      assert_select "[data-testid='record-changed-notice']", /申請した後に、勤怠記録が変わっています/
      post_review(correction_request, decision: "approve")
      assert_equal "従業 花子 さんの 11/24(火) の打刻修正申請を承認しました。勤怠記録の出勤・休憩を申請内容どおりに更新しました（退勤は今の記録のままです）。",
                   flash[:notice]
    end
    attendance = @employee.attendances.find_by!(work_date: Date.new(2026, 11, 24))
    assert_equal t(24, 8), attendance.clock_in_at
    assert_nil attendance.clock_out_at
  end
end
