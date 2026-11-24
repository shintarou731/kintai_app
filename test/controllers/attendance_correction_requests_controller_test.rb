require "test_helper"

class AttendanceCorrectionRequestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @user = users(:employee)
  end

  def t(day, hour, min = 0)
    Time.zone.local(2026, 11, day, hour, min)
  end

  def work(clock_in, clock_out, breaks: [], user: @user)
    record = user.attendances.create!(work_date: clock_in.to_date, clock_in_at: clock_in, clock_out_at: clock_out)
    breaks.each { |from, to| record.breaks.create!(started_at: from, ended_at: to) }
    record
  end

  def correction_params(date: "2026-11-20", clock_in: "09:00", clock_out: "18:00", clock_out_day: "0",
                        breaks: {}, reason: "退勤の打刻を忘れました")
    { attendance_correction_request: { target_date: date, clock_in_time: clock_in, clock_out_time: clock_out,
                                       clock_out_day: clock_out_day, reason: reason, break_inputs: breaks } }
  end

  test "未ログインではログイン画面へ移動し、申請は作られない" do
    get new_attendance_correction_request_path(date: "2026-11-20")
    assert_redirected_to login_path
    post attendance_correction_requests_path, params: correction_params
    assert_redirected_to login_path
    assert_equal 0, ApprovalRequest.count
  end

  test "入力画面には対象日と今の記録が出て、入力欄に今の時刻が入っている" do
    work(t(20, 9), t(20, 18, 30), breaks: [ [ t(20, 12), t(20, 13) ] ])
    travel_to NOW do
      sign_in_as @user
      get new_attendance_correction_request_path(date: "2026-11-20")
      assert_response :success
      assert_select "h1", /打刻修正申請/
      assert_select "[data-testid='correction-target-date']", "2026年11月20日(金)"
      assert_select "[data-testid='current-record']", /09:00.*18:30.*12:00〜13:00/m
      assert_select "input[name='attendance_correction_request[target_date]'][value='2026-11-20']"
      assert_select "input[type='time'][name='attendance_correction_request[clock_in_time]'][value='09:00']"
      assert_select "input[type='time'][name='attendance_correction_request[clock_out_time]'][value='18:30']"
      assert_select "select[name='attendance_correction_request[clock_out_day]'] option", 2
      assert_select "select[name='attendance_correction_request[clock_out_day]'] option[value='1']", "翌日 11/21(土)"
      assert_select "[data-testid='break-row'] input[name='attendance_correction_request[break_inputs][0][start_time]'][value='12:00']"
      assert_select "[data-testid='break-row'] input[name='attendance_correction_request[break_inputs][0][end_time]'][value='13:00']"
      assert_select "textarea[name='attendance_correction_request[reason]'][required]"
      assert_select ".header__nav a.nav__link.is-active[href='#{approval_requests_path}']", "申請"
    end
  end

  test "打刻が全く無い日も入力画面を開ける（欄は空、休憩は空の1行）" do
    travel_to NOW do
      sign_in_as @user
      get new_attendance_correction_request_path(date: "2026-11-03")
      assert_response :success
      assert_select "[data-testid='current-record']", /この日の打刻はありません/
      assert_select "input[name='attendance_correction_request[clock_in_time]']:not([value])"
      assert_select "[data-testid='correction-breaks'] ol [data-testid='break-row']", 1
    end
  end

  test "今日も申請できる。勤務中でありうる今日は退勤を空欄にできると案内する" do
    travel_to NOW do
      sign_in_as @user
      get new_attendance_correction_request_path(date: "2026-11-24")
      assert_response :success
      assert_select "label[for='attendance_correction_request_clock_out_time'] .form__optional", "勤務中なら空欄"
    end
  end

  test "未来の日付・日付でない値・日付なしは入力画面を出さない" do
    travel_to NOW do
      sign_in_as @user
      get new_attendance_correction_request_path(date: "2026-11-25")
      assert_redirected_to attendances_path(month: "2026-11")
      assert_equal "未来の日付（11/25(水)）は修正申請できません。今日までの日付を選んでください。", flash[:alert]

      [ "abc", "2026-02-30", "", "2026-11-1" ].each do |value|
        get new_attendance_correction_request_path(date: value)
        assert_redirected_to approval_requests_path
        assert_equal "修正申請する日付を正しく指定してください。", flash[:alert]
      end
      get new_attendance_correction_request_path
      assert_redirected_to approval_requests_path
    end
  end

  test "申請すると承認待ちになり、申請一覧に出る。勤怠記録は変わらない" do
    record = work(t(20, 9), nil)
    travel_to NOW do
      sign_in_as @user
      assert_difference -> { AttendanceCorrectionRequest.count }, 1 do
        post attendance_correction_requests_path,
             params: correction_params(clock_out: "18:00",
                                       breaks: { "0" => { start_time: "12:00", start_day: "0", end_time: "13:00", end_day: "0" },
                                                 "1" => { start_time: "", start_day: "0", end_time: "", end_day: "0" } })
      end
      assert_redirected_to approval_requests_path
      assert_equal "11/20(金) の打刻修正を申請しました（承認待ち）。承認されるまで勤怠記録は変わりません。", flash[:notice]

      request = AttendanceCorrectionRequest.last
      assert request.pending?
      assert_equal @user, request.user
      assert_equal 1, request.breaks.count
      assert_nil record.reload.clock_out_at
      assert_equal 0, record.breaks.count

      follow_redirect!
      assert_select "[data-testid='request-row'].is-highlighted", 1
      assert_select "[data-testid='request-row'] td[data-column='target-date']", "11/20(金)"
      assert_select "[data-testid='request-row'] td[data-column='kind']", "打刻修正"
      assert_select "[data-testid='request-row'] td[data-column='submitted-at']", "11/24 10:30"
      assert_select "[data-testid='request-row'] td[data-column='status']", "承認待ち"
      assert_select "[data-testid='request-row'] td[data-column='summary']", "出勤 09:00／退勤 18:00／休憩 1回"
    end
  end

  test "日付をまたぐ勤務（退勤が翌日）を申請できる" do
    travel_to NOW do
      sign_in_as @user
      post attendance_correction_requests_path, params: correction_params(clock_in: "22:00", clock_out: "02:00", clock_out_day: "1")
      assert_redirected_to approval_requests_path
      assert_equal t(21, 2), AttendanceCorrectionRequest.last.requested_clock_out_at
      follow_redirect!
      assert_select "td[data-column='summary']", "出勤 22:00／退勤 翌 02:00／休憩 0回"
    end
  end

  test "理由が空・矛盾した時刻は申請できず、入力した値を残してエラーを出す" do
    travel_to NOW do
      sign_in_as @user
      assert_no_difference -> { ApprovalRequest.count } do
        post attendance_correction_requests_path,
             params: correction_params(clock_in: "09:00", clock_out: "08:00", reason: "",
                                       breaks: { "0" => { start_time: "12:00", start_day: "0", end_time: "11:00", end_day: "0" } })
      end
      assert_response :unprocessable_entity
      assert_select ".form-errors__title", "入力内容を確認してください（3件）"
      assert_select ".form-errors", /理由を入力してください/
      assert_select ".form-errors", /退勤時刻は出勤時刻より後にしてください/
      assert_select ".form-errors", /休憩1の終了時刻は開始時刻より後にしてください/
      assert_select ".field_with_errors input[name='attendance_correction_request[clock_out_time]'][value='08:00']"
      assert_select "[data-testid='break-row'].is-invalid input[value='11:00']"
    end
  end

  test "休憩の重なり・勤務時間外はエラー" do
    travel_to NOW do
      sign_in_as @user
      post attendance_correction_requests_path,
           params: correction_params(breaks: { "0" => { start_time: "12:00", start_day: "0", end_time: "13:00", end_day: "0" },
                                               "1" => { start_time: "12:30", start_day: "0", end_time: "13:30", end_day: "0" },
                                               "2" => { start_time: "18:30", start_day: "0", end_time: "19:00", end_day: "0" } })
      assert_response :unprocessable_entity
      assert_select ".form-errors", /休憩1と休憩2の時間が重なっています/
      assert_select ".form-errors", /休憩3は勤務時間（09:00〜18:00）の中に入れてください/
      assert_select "[data-testid='break-row'].is-invalid", 3
    end
  end

  test "未来の日付を直接送っても申請できない" do
    travel_to NOW do
      sign_in_as @user
      assert_no_difference -> { ApprovalRequest.count } do
        post attendance_correction_requests_path, params: correction_params(date: "2026-11-25")
      end
      assert_redirected_to attendances_path(month: "2026-11")
    end
  end

  test "同じ日に承認待ちの申請があると、入力画面は既存の申請へ戻し、直接送信も重複しない" do
    travel_to NOW do
      sign_in_as @user
      post attendance_correction_requests_path, params: correction_params
      existing = AttendanceCorrectionRequest.last

      get new_attendance_correction_request_path(date: "2026-11-20")
      assert_redirected_to approval_request_path(existing)
      assert_match "11/20(金) にはすでに承認待ちの修正申請があります", flash[:alert]

      assert_no_difference -> { ApprovalRequest.count } do
        post attendance_correction_requests_path, params: correction_params(clock_in: "09:30")
      end
      assert_redirected_to approval_request_path(existing)
    end
  end

  test "パラメーターが欠けていても 400 にならない" do
    travel_to NOW do
      sign_in_as @user
      post attendance_correction_requests_path
      assert_redirected_to approval_requests_path
      assert_equal "修正申請する日付を正しく指定してください。", flash[:alert]

      post attendance_correction_requests_path, params: { attendance_correction_request: { target_date: "2026-11-20" } }
      assert_response :unprocessable_entity
      assert_select ".form-errors", /出勤時刻を入力してください/
      assert_select ".form-errors", /理由を入力してください/
      assert_equal 0, ApprovalRequest.count
    end
  end

  test "申請者は必ずログイン中の本人になる（他人の ID を送っても無視する）" do
    travel_to NOW do
      sign_in_as @user
      params = correction_params
      params[:attendance_correction_request][:user_id] = users(:admin).id
      post attendance_correction_requests_path, params: params
      assert_equal @user, AttendanceCorrectionRequest.last.user
    end
  end
end
