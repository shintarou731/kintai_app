require "test_helper"

class ApprovalRequestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @user = users(:employee)
    @other = users(:admin)
  end

  def t(day, hour, min = 0)
    Time.zone.local(2026, 11, day, hour, min)
  end

  def correction(user: @user, date: Date.new(2026, 11, 20), clock_in: "09:00", clock_out: "18:00", status: nil, at: NOW)
    request = user.attendance_correction_requests.new(target_date: date, clock_in_time: clock_in, clock_out_time: clock_out,
                                                      reason: "打刻を忘れました\n18:00 に退勤しています")
    travel_to(at) { assert request.submit, request.errors.full_messages.inspect }
    request.update_column(:status, status) if status
    request
  end

  def row(date)
    "tr[data-date='#{date.iso8601}']"
  end

  test "未ログインではログイン画面へ移動する" do
    request = correction
    get approval_requests_path
    assert_redirected_to login_path
    get approval_request_path(request)
    assert_redirected_to login_path
    post approval_request_withdrawal_path(request)
    assert_redirected_to login_path
    assert request.reload.pending?
  end

  test "ヘッダーのナビに「申請」があり、表示中は選択状態になる" do
    sign_in_as @user
    get root_path
    assert_select ".header__nav a.nav__link[href='#{approval_requests_path}']", "申請"
    get approval_requests_path
    assert_select ".header__nav a.nav__link.is-active[href='#{approval_requests_path}'][aria-current='page']", "申請"
  end

  test "一覧には自分の申請だけが新しい順に並び、承認待ちで絞り込める" do
    mine_old = correction(date: Date.new(2026, 11, 18), at: t(19, 9))
    mine_new = correction(date: Date.new(2026, 11, 20), at: t(21, 9))
    correction(date: Date.new(2026, 11, 19), status: "withdrawn", at: t(20, 9))
    others = correction(user: @other, date: Date.new(2026, 11, 17))

    travel_to NOW do
      sign_in_as @user
      get approval_requests_path
      assert_response :success
      assert_select "[data-testid='request-row']", 3
      assert_select "[data-testid='request-row']:first-child##{ActionView::RecordIdentifier.dom_id(mine_new)}"
      assert_select "##{ActionView::RecordIdentifier.dom_id(others)}", 0
      assert_select "[data-testid='filter-all'] .tabs__count", "3"
      assert_select "[data-testid='filter-pending'] .tabs__count", "2"
      assert_select "td[data-column='status']", "取り下げ"
      assert_select "thead th", /対象日|種類|内容|申請日|状態/

      get approval_requests_path(status: "pending")
      assert_select "[data-testid='request-row']", 2
      assert_select "##{ActionView::RecordIdentifier.dom_id(mine_old)}", 1
      assert_select "td[data-column='status']", text: "取り下げ", count: 0
    end
  end

  test "申請が無いときは空の案内と、日付を選んで申請するフォームが出る" do
    travel_to NOW do
      sign_in_as @user
      get approval_requests_path
      assert_select "[data-testid='requests-empty']", /まだ申請はありません/
      assert_select "[data-testid='new-correction-form'][action='#{new_attendance_correction_request_path}'][method='get']"
      assert_select "[data-testid='new-correction-form'] input[type='date'][name='date'][max='2026-11-24']"
    end
  end

  test "詳細には今の記録と申請内容が並び、変わる項目が分かる。理由も出る" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 20), clock_in_at: t(20, 9))
    request = correction
    travel_to NOW do
      sign_in_as @user
      get approval_request_path(request)
      assert_response :success
      assert_select "h1", /打刻修正申請.*2026年11月20日\(金\).*承認待ち/m
      assert_select "[data-testid='correction-comparison'] tr[data-item='出勤']:not(.is-changed) td[data-column='current']", "09:00"
      assert_select "[data-testid='correction-comparison'] tr[data-item='退勤'].is-changed td[data-column='current']", "未打刻"
      assert_select "[data-testid='correction-comparison'] tr[data-item='退勤'].is-changed td[data-column='requested']", "18:00"
      assert_select "[data-testid='correction-comparison'] tr[data-item='実働時間'] td[data-column='requested']", "9:00"
      assert_select "[data-testid='request-reason']", /打刻を忘れました\s+18:00 に退勤しています/
      assert_select "[data-testid='withdraw-button']", "この申請を取り下げる"
    end
  end

  test "他人の申請・存在しない申請は見られない" do
    others = correction(user: @other)
    sign_in_as @user
    get approval_request_path(others)
    assert_redirected_to approval_requests_path
    assert_equal "指定された申請が見つかりません。一覧から選び直してください。", flash[:alert]
    get approval_request_path(id: 999_999)
    assert_redirected_to approval_requests_path
    get "/requests/abc"
    assert_response :not_found
  end

  test "承認待ちの申請は本人が取り下げられ、勤怠記録は変わらない" do
    record = @user.attendances.create!(work_date: Date.new(2026, 11, 20), clock_in_at: t(20, 9))
    request = correction
    travel_to NOW do
      sign_in_as @user
      post approval_request_withdrawal_path(request)
      assert_redirected_to approval_request_path(request)
      assert_equal "11/20(金) の打刻修正申請を取り下げました。勤怠記録は変わりません。", flash[:notice]
      assert request.reload.withdrawn?
      assert_equal NOW, request.withdrawn_at
      assert_nil record.reload.clock_out_at

      follow_redirect!
      assert_select "h1 [data-testid='request-status']", "取り下げ"
      assert_select "[data-testid='withdraw-button']", 0
      assert_select "[data-testid='request-meta']", /取り下げ日時.*2026年11月24日\(火\) 10:30/m
      assert_select "a[href=?]", new_attendance_correction_request_path(date: "2026-11-20"), text: "この日の修正申請を出し直す"

      # 取り下げ済みをもう一度取り下げても変わらない
      post approval_request_withdrawal_path(request)
      assert_match "「取り下げ」のため、取り下げできません", flash[:alert]
    end
  end

  test "承認済み・却下の申請は、直接送信しても取り下げできない" do
    approved = correction(date: Date.new(2026, 11, 18), status: "approved")
    rejected = correction(date: Date.new(2026, 11, 19), status: "rejected")
    sign_in_as @user

    { approved => "承認済み", rejected => "却下" }.each do |request, label|
      get approval_request_path(request)
      assert_select "[data-testid='withdraw-button']", 0
      assert_select "[data-testid='request-actions']", /処理済みの申請は取り下げできません/

      post approval_request_withdrawal_path(request)
      assert_redirected_to approval_request_path(request)
      assert_match "「#{label}」のため、取り下げできません", flash[:alert]
      assert_equal label == "却下" ? "rejected" : "approved", request.reload.status
      assert_nil request.withdrawn_at
    end
  end

  test "他人の申請は取り下げできない" do
    others = correction(user: @other)
    sign_in_as @user
    post approval_request_withdrawal_path(others)
    assert_redirected_to approval_requests_path
    assert others.reload.pending?
  end

  test "勤怠履歴：承認待ちの日に「申請中」、今日までの日に「修正申請」が出て、未来の日には出ない" do
    request = correction
    travel_to NOW do
      sign_in_as @user
      get attendances_path
      assert_select "#{row(Date.new(2026, 11, 20))} [data-testid='pending-correction'][href='#{approval_request_path(request)}']", "申請中"
      assert_select "#{row(Date.new(2026, 11, 20))} [data-testid='correction-link']", 0
      assert_select "#{row(Date.new(2026, 11, 3))} [data-testid='correction-link'][href=?]",
                    new_attendance_correction_request_path(date: "2026-11-03"), text: "修正申請"
      assert_select "#{row(Date.new(2026, 11, 24))} [data-testid='correction-link']", "修正申請"
      assert_select "#{row(Date.new(2026, 11, 25))} [data-testid='correction-link']", 0
      assert_select "#{row(Date.new(2026, 11, 25))} td[data-column='request']", ""

      # 取り下げると「申請中」は消える
      request.withdraw
      get attendances_path
      assert_select "#{row(Date.new(2026, 11, 20))} [data-testid='pending-correction']", 0
      assert_select "#{row(Date.new(2026, 11, 20))} [data-testid='correction-link']", 1
    end
  end

  test "他人の承認待ちの申請は、自分の勤怠履歴に「申請中」と出ない" do
    correction(user: @other)
    travel_to NOW do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='pending-correction']", 0
    end
  end

  test "退勤漏れのお知らせから修正申請へ進める（履歴・ホーム）" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 20), clock_in_at: t(20, 9))
    travel_to NOW do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='missing-clock-out-closed']", /修正申請で、実際に退勤した時刻を申請してください/
      assert_select "[data-testid='missing-clock-out-closed'] a[href=?]", new_attendance_correction_request_path(date: "2026-11-20"),
                    text: "11/20(金) の修正申請"

      get root_path
      assert_select "[data-testid='missing-clock-outs']", /修正申請で、実際に退勤した時刻を申請してください/
      assert_select "[data-testid='missing-clock-out-request-link'][href=?]", new_attendance_correction_request_path(date: "2026-11-20"),
                    text: "11/20(金) の修正申請をする"
    end

    request = correction
    travel_to NOW do
      get root_path
      assert_select "[data-testid='missing-clock-out-pending-link'][href='#{approval_request_path(request)}']", "11/20(金) は申請中"
      get attendances_path
      assert_select "[data-testid='missing-clock-out-closed'] a[href='#{approval_request_path(request)}']", "11/20(金) は申請中"
    end
  end
end
