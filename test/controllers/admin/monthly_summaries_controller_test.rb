require "test_helper"

# 月次集計と締め（F14）の画面：集計の表・警告・締め／解除・締め済みの表示の固定・日別の勤怠・管理者の直接修正と履歴・権限
class Admin::MonthlySummariesControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 12, 5, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
  end

  teardown { travel_back }

  def at(date, hour, minute = 0)
    Time.zone.local(date.year, date.month, date.day, hour, minute)
  end

  def nov(day)
    Date.new(2026, 11, day)
  end

  def work!(user, date, from, to, lunch: true)
    attendance = Attendance.create!(user: user, work_date: date, clock_in_at: at(date, *from), clock_out_at: to && at(date, *to))
    attendance.breaks.create!(started_at: at(date, 12), ended_at: at(date, 13)) if lunch
    attendance
  end

  def row(user)
    "[data-testid='monthly-summary-row'][data-user-id='#{user.id}']"
  end

  def set_rules!(**values)
    setting = WorkRuleSetting.current
    values.each { |key, value| setting.public_send(:"#{key}=", value) }
    setting.save!
  end

  def build_november
    work!(@employee, nov(10), [ 9, 0 ], [ 18, 0 ])                 # 実働 8:00
    work!(@employee, nov(21), [ 9, 0 ], [ 19, 0 ])                 # 土曜・実働 9:00・残業 1:00
    work!(@employee, nov(24), [ 21, 0 ], nil, lunch: false).update!(clock_out_at: at(nov(25), 1, 0)) # 深夜 3:00
    Attendance.create!(user: @employee, work_date: nov(26), clock_in_at: at(nov(26), 9)) # 退勤漏れ
    paid = LeaveRequest.new(user: @employee, leave_type: "paid", day_part: "morning", target_date: nov(27), end_date: nov(27),
                            reason: "通院", status: "approved")
    paid.save!(validate: false)
    absence = LeaveRequest.new(user: @employee, leave_type: "absence", target_date: nov(30), end_date: nov(30), reason: "体調不良", status: "approved")
    absence.save!(validate: false)
    @pending = @employee.attendance_correction_requests.new(target_date: nov(26), clock_in_time: "09:00", clock_out_time: "18:00", reason: "退勤忘れ")
    assert @pending.submit
  end

  test "管理メニューから開け、選んだ月度の全員の集計・期間・警告を表で見られる" do
    build_november
    sign_in_as @admin
    get admin_monthly_summaries_path(month: "2026-11")
    assert_response :success
    assert_select "[data-testid='nav-monthly'][aria-current='page']"
    assert_select "[data-testid='period-label']", text: /2026年11月/
    assert_select "[data-testid='period-range']", text: "11/1(日)〜11/30(月)"
    assert_select "[data-testid='closing-status'][data-status='open']", text: "未締め"

    assert_select row(@employee) do
      assert_select "[data-column='working-days']", text: "4日"
      assert_select "[data-column='worked']", text: "21:00"
      assert_select "[data-column='overtime']", text: "1:00"
      assert_select "[data-column='night']", text: "3:00"
      assert_select "[data-column='holiday']", text: "9:00"
      assert_select "[data-column='paid-leave']", text: "0.5日"
      assert_select "[data-column='absent']", text: /0回/
      assert_select "[data-testid='absence-leave-days']", text: "ほか欠勤の休暇 1日"
      assert_select "[data-testid='row-missing']", text: "退勤漏れ 1"
    end
    assert_select row(@admin)
    assert_select "[data-testid='summary-definitions']", text: /欠勤の回数には、種類が「欠勤」の承認済み休暇を含めていません/
    assert_select "[data-testid='warning-missing']", text: /退勤漏れ 1件/
    assert_select "[data-testid='warning-pending']", text: /承認待ちの申請 1件\s*（打刻修正 1件/
    assert_select "[data-testid='close-button'][data-turbo-confirm*='退勤漏れ 1件・承認待ちの申請 1件']"
    assert_select "[data-testid='month-list-row'][data-month='2026-11'] [data-testid='closing-status']", text: "未締め"
  end

  test "締めると「締め済み」になり、締めの記録が残る。勤務ルールを変えても締めた月度の表示は変わらない" do
    build_november
    sign_in_as @admin
    post admin_monthly_closing_path, params: { month: "2026-11" }
    assert_redirected_to admin_monthly_summaries_path(month: "2026-11")
    follow_redirect!
    assert_select ".flash--notice", text: /2026年11月（11\/1\(日\)〜11\/30\(月\)）を締めました/
    assert_select "[data-testid='closing-status'][data-status='closed']", text: "締め済み"
    assert_select "[data-testid='closing-card']", text: /管理 太郎 が 12\/5 10:00 に締めました/
    assert_select "[data-testid='closed-pending-note']", text: /承認待ちのまま締めた申請が 1件/
    assert_select "[data-testid='closing-history-row']", count: 1
    assert_select "[data-testid='month-list-row'][data-month='2026-11'] [data-testid='closing-status']", text: "締め済み"

    set_rules!(scheduled_work_time: "7:00", closing_day: 20)
    get admin_monthly_summaries_path(month: "2026-11")
    assert_select "[data-testid='period-range']", text: "11/1(日)〜11/30(月)"
    assert_select row(@employee) do
      assert_select "[data-column='overtime']", text: "1:00"
      assert_select "[data-column='worked']", text: "21:00"
    end
    # 12月度は締め済みの11月に合わせて 12/1 から（20日締めなので 12/20 まで）
    get admin_monthly_summaries_path(month: "2026-12")
    assert_select "[data-testid='period-range']", text: "12/1(火)〜12/20(日)"
    assert_select "[data-testid='adjusted-period-note']"

    # 従業員の勤怠履歴（F5）も、締めた時点の値・期間で表示される
    delete logout_path
    sign_in_as @employee
    get attendances_path(month: "2026-11")
    assert_select "[data-testid='period-range']", text: "11/1(日)〜11/30(月)"
    assert_select "[data-testid='closed-period-notice']", text: /所定労働時間 8:00/
    assert_select "[data-testid='total-overtime']", text: "1:00"
    assert_select "tr[data-date='2026-11-10'] [data-column='overtime']", text: "0:00"
    assert_select "tr[data-date='2026-11-10'] [data-testid='closed-day']", text: "締め済み"
    assert_select "[data-testid='correction-link']", 0
    get new_attendance_correction_request_path(date: "2026-11-11")
    assert_redirected_to attendances_path(month: "2026-11")
    assert_match "締め済みの月度", flash[:alert]
  end

  test "締めを解除すると、解除した記録が残り、今の勤務ルールで計算し直す" do
    build_november
    MonthlyClosing.close!(year: 2026, month: 11, by: @admin)
    set_rules!(scheduled_work_time: "7:00")
    sign_in_as @admin
    get admin_monthly_summaries_path(month: "2026-11")
    assert_select "[data-testid='reopen-button'][data-turbo-confirm*='所定労働時間 7:00']"

    delete admin_monthly_closing_path, params: { month: "2026-11" }
    assert_redirected_to admin_monthly_summaries_path(month: "2026-11")
    follow_redirect!
    assert_select ".flash--notice", text: /締めを解除しました/
    assert_select "[data-testid='closing-status'][data-status='open']"
    assert_select row(@employee) { assert_select "[data-column='overtime']", text: "4:00" } # 1:00 + 2:00 + 1:00（7:00 を超えた分）
    assert_select "[data-testid='closing-history-row'] [data-column='reopened']", text: /管理 太郎（12\/5 10:00）/

    delete admin_monthly_closing_path, params: { month: "2026-11" }
    follow_redirect!
    assert_select ".flash--alert", text: /締められていません/
  end

  test "終わっていない月度は締められず、二重に締めてもエラーになる。GET で開いたら月次集計へ戻す" do
    sign_in_as @admin
    get admin_monthly_summaries_path(month: "2026-12")
    assert_select "[data-testid='close-button']", 0
    assert_select "[data-testid='closing-not-ended']", text: /1\/1\(金\)以降に締められます/
    post admin_monthly_closing_path, params: { month: "2026-12" }
    follow_redirect!
    assert_select ".flash--alert", text: /まだ終わっていないため、締められません/

    post admin_monthly_closing_path, params: { month: "2026-11" }
    post admin_monthly_closing_path, params: { month: "2026-11" }
    follow_redirect!
    assert_select ".flash--alert", text: /すでに締め済み/
    assert_equal 1, MonthlyClosing.count

    get admin_monthly_closing_path(month: "2026-11")
    assert_redirected_to admin_monthly_summaries_path(month: "2026-11")
    post admin_monthly_closing_path, params: { month: "abc" }
    assert_redirected_to admin_monthly_summaries_path
  end

  test "従業員の行から日別の勤怠を開き、直接修正（理由必須）でき、修正前・修正後の履歴が見られる" do
    attendance = Attendance.create!(user: @employee, work_date: nov(26), clock_in_at: at(nov(26), 9))
    sign_in_as @admin
    get admin_monthly_summaries_path(month: "2026-11")
    assert_select "#{row(@employee)} [data-testid='monthly-detail-link'][href='#{admin_monthly_summary_path(@employee, month: '2026-11')}']"

    get admin_monthly_summary_path(@employee, month: "2026-11")
    assert_response :success
    assert_select "[data-testid='monthly-user-title']", text: /従業 花子 さん：2026年11月/
    assert_select "tr[data-date='2026-11-26'] [data-testid='admin-edit-link']", text: "修正"
    assert_select "tr[data-date='2026-11-27'] [data-testid='admin-edit-link']", text: "作成"
    assert_select "[data-testid='attendance-edits-empty']"

    get admin_edit_attendance_record_path(@employee.id, "2026-11-26")
    assert_response :success
    token = css_select("input[name='attendance_record_editor[record_token]']").first["value"]

    patch admin_attendance_record_path(@employee.id, "2026-11-26"),
          params: { attendance_record_editor: { clock_in_time: "09:00", clock_out_time: "18:00", clock_out_day: "0", reason: "",
                                                record_token: token } }
    assert_response :unprocessable_entity
    assert_select ".form-errors", text: /理由を入力してください/
    assert_nil attendance.reload.clock_out_at

    patch admin_attendance_record_path(@employee.id, "2026-11-26"),
          params: { attendance_record_editor: { clock_in_time: "09:00", clock_out_time: "18:00", clock_out_day: "0",
                                                reason: "本人から退勤時刻の連絡", record_token: token,
                                                break_inputs: { "0" => { start_time: "12:00", start_day: "0", end_time: "13:00", end_day: "0" } } } }
    assert_redirected_to admin_monthly_summary_path(@employee, month: "2026-11")
    follow_redirect!
    assert_select ".flash--notice", text: /勤怠を修正しました/
    assert_equal at(nov(26), 18), attendance.reload.clock_out_at
    assert_select "tr[data-date='2026-11-26'] [data-column='worked']", text: "8:00"
    assert_select "tr[data-date='2026-11-26'] [data-testid='edited-badge']", text: "修正履歴 1"
    assert_select "[data-testid='attendance-edit-row'][data-operation='updated']" do
      assert_select "td", text: /管理 太郎/
      assert_select "[data-column='before']", text: /退勤 未打刻/
      assert_select "[data-column='after']", text: /退勤 18:00/
      assert_select "[data-column='after']", text: /実働 8:00/
      assert_select "[data-column='reason']", text: "本人から退勤時刻の連絡"
    end

    delete admin_attendance_record_path(@employee.id, "2026-11-26"),
           params: { attendance_record_delete: { reason: "誤打刻", record_token: AttendanceRecordEditor.token_for(attendance.reload) } }
    assert_redirected_to admin_monthly_summary_path(@employee, month: "2026-11")
    assert_not Attendance.exists?(attendance.id)
    assert_equal %w[deleted updated], AttendanceEdit.recent_first.pluck(:operation)
  end

  test "締め済みの月度の日別の勤怠には修正の操作が出ず、直接送っても直せない" do
    attendance = work!(@employee, nov(10), [ 9, 0 ], [ 18, 0 ])
    MonthlyClosing.close!(year: 2026, month: 11, by: @admin)
    sign_in_as @admin
    get admin_monthly_summary_path(@employee, month: "2026-11")
    assert_select "[data-testid='admin-edit-link']", 0
    assert_select "[data-testid='closed-period-notice']"

    get admin_edit_attendance_record_path(@employee.id, "2026-11-10")
    assert_select "[data-testid='edit-blockers']", text: /締め済みの月度/
    assert_select "[data-testid='record-edit-form']", 0

    patch admin_attendance_record_path(@employee.id, "2026-11-10"),
          params: { attendance_record_editor: { clock_in_time: "08:00", clock_out_time: "18:00", reason: "直す" } }
    assert_response :unprocessable_entity
    assert_equal at(nov(10), 9), attendance.reload.clock_in_at
    delete admin_attendance_record_path(@employee.id, "2026-11-10"), params: { attendance_record_delete: { reason: "消す" } }
    assert_response :unprocessable_entity
    assert Attendance.exists?(attendance.id)
  end

  test "直せない日の直接修正の画面には「保存すると、新しく作ります」を出さない（直せる日には出す）" do
    other_admin = users(:inactive_employee)
    other_admin.update!(role: "admin", active: true) # 有効な管理者が2人 → 自分の勤怠は直せない
    sign_in_as @admin
    get admin_edit_attendance_record_path(@admin.id, "2026-11-10")
    assert_select "[data-testid='edit-blockers']"
    assert_select "[data-testid='current-record-empty']", text: "この日の勤怠はありません。"
    assert_no_match "保存すると、新しく作ります", response.body

    MonthlyClosing.close!(year: 2026, month: 11, by: @admin)
    get admin_edit_attendance_record_path(@employee.id, "2026-11-11")
    assert_select "[data-testid='edit-blockers']", text: /締め済みの月度/
    assert_no_match "保存すると、新しく作ります", response.body

    get admin_edit_attendance_record_path(@employee.id, "2026-12-01")
    assert_select "[data-testid='edit-blockers']", 0
    assert_select "[data-testid='current-record-empty']", text: "この日の勤怠はありません。保存すると、新しく作ります。"
  end

  test "締め済みの月度の勤怠履歴では、退勤漏れの案内で修正申請へ誘導しない" do
    Attendance.create!(user: @employee, work_date: nov(26), clock_in_at: at(nov(26), 9)) # 退勤漏れ
    sign_in_as @employee
    get attendances_path(month: "2026-11")
    assert_select "[data-testid='missing-clock-out-closed']", text: /修正申請で、実際に退勤した時刻を申請してください/
    assert_select "[data-testid='missing-clock-out-request-link']", 1

    MonthlyClosing.close!(year: 2026, month: 11, by: @admin)
    get attendances_path(month: "2026-11")
    assert_select "[data-testid='missing-clock-out-closed']", text: /11\/26\(木\)\s*は退勤の打刻がありません。\s*この月は締め済みのため、修正申請はできません。実際に退勤した時刻は、管理者に連絡してください。/
    assert_select "[data-testid='missing-clock-out-closed']", text: /修正申請で、実際に退勤した時刻を申請してください/, count: 0
    assert_select "[data-testid='missing-clock-out-request-link']", 0
    assert_select "a[href^='#{new_attendance_correction_request_path}']", 0
  end

  test "承認待ちのまま締めた申請は、承認画面で承認できない（ボタンが押せず、送ってもエラー）" do
    build_november
    MonthlyClosing.close!(year: 2026, month: 11, by: @admin)
    sign_in_as @admin
    get admin_approval_request_path(@pending)
    assert_select "[data-testid='approval-blockers']", text: /締め済みの月度/
    assert_select "[data-testid='approve-button'][disabled]"
    post admin_approval_request_review_path(@pending), params: { approval_review: { decision: "approve" } }
    assert_response :unprocessable_entity
    assert @pending.reload.pending?
  end

  test "従業員は月次集計・締め・直接修正のどれも使えない" do
    attendance = work!(@employee, nov(10), [ 9, 0 ], [ 18, 0 ])
    sign_in_as @employee
    [ -> { get admin_monthly_summaries_path }, -> { get admin_monthly_summary_path(@employee) },
      -> { post admin_monthly_closing_path, params: { month: "2026-11" } },
      -> { get admin_edit_attendance_record_path(@employee.id, "2026-11-10") },
      -> { patch admin_attendance_record_path(@employee.id, "2026-11-10"), params: { attendance_record_editor: { clock_in_time: "08:00", reason: "x" } } } ].each do |request|
      request.call
      assert_redirected_to root_path
    end
    assert_equal 0, MonthlyClosing.count
    assert_equal at(nov(10), 9), attendance.reload.clock_in_at
  end
end
