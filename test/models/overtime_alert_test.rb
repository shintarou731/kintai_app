require "test_helper"
require "minitest/mock"

# 残業の警告（F16）：警告ライン（F6）の 80%・100% を超えたときに、月度ごとに1回ずつ、本人と管理者に届くこと。
# 判定のきっかけ（退勤・修正申請の承認・管理者の直接修正・勤務ルールの変更）と、失敗しても元の処理が成功すること
class OvertimeAlertTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include Rails.application.routes.url_helpers

  NOW = Time.zone.local(2026, 11, 25, 20, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    # 警告ライン 10時間：80% は 8:00（480分）を超えたら、100% は 10:00（600分）を超えたら
    set_rules!(overtime_warning_hours: 10)
  end

  teardown { travel_back }

  def set_rules!(**values)
    setting = WorkRuleSetting.current
    values.each { |key, value| setting.public_send(:"#{key}=", value) }
    setting.save!
  end

  def at(date, hour, minute = 0)
    Time.zone.local(date.year, date.month, date.day, hour, minute)
  end

  # date に、休憩なしで「所定 8:00 ＋ 残業 overtime 分」働いた勤怠を作る（9:00 出勤）
  def overtime!(date, overtime, user: @employee)
    Attendance.create!(user: user, work_date: date, clock_in_at: at(date, 9), clock_out_at: at(date, 17) + overtime.minutes)
  end

  def nov(day)
    Date.new(2026, 11, day)
  end

  def check(user = @employee, date: NOW.to_date)
    OvertimeAlert.check(user, date: date)
  end

  def employee_alerts
    Notification.where(recipient: @employee, kind: "overtime_alert").order(:id).to_a
  end

  test "ちょうど80%（8:00）では届かず、8:01 で本人と管理者に1回だけ届く。同じ月度にもう一度判定しても増えない" do
    overtime!(nov(2), 240)
    overtime!(nov(3), 240)
    assert_empty check
    assert_equal 0, Notification.count

    overtime!(nov(4), 1)
    alerts = check
    assert_equal [ 80 ], alerts.map(&:level)
    assert_equal "2026-11", alerts.first.period_key
    assert_equal 481, alerts.first.overtime_minutes

    note = employee_alerts.sole
    assert_equal "2026年11月の残業が警告ライン（10時間）の80%を超えました", note.title
    assert_match "今の残業時間は 8:01 です（11/1〜11/30）", note.body
    assert_equal attendances_path(month: "2026-11"), note.path
    admin_note = Notification.find_by!(recipient: @admin, kind: "overtime_alert")
    assert_equal "従業 花子 さんの2026年11月の残業が警告ライン（10時間）の80%を超えました", admin_note.title
    assert_equal admin_monthly_summary_path(@employee, month: "2026-11"), admin_note.path

    3.times { assert_empty check }
    overtime!(nov(5), 60)
    assert_empty check, "80% は送り済み・100% はまだ超えていない"
    assert_equal 1, employee_alerts.size
    assert_equal 2, Notification.count
  end

  test "ちょうど100%（10:00）では100%の通知は届かず、10:01 で1回だけ届く" do
    overtime!(nov(2), 300)
    overtime!(nov(3), 300)
    assert_equal [ 80 ], check.map(&:level)
    overtime!(nov(4), 1)
    assert_equal [ 100 ], check.map(&:level)
    assert_empty check

    titles = employee_alerts.map(&:title)
    assert_equal [ "2026年11月の残業が警告ライン（10時間）の80%を超えました", "2026年11月の残業が警告ライン（10時間）を超えました" ], titles
    assert_equal 2, Notification.where(recipient: @admin, kind: "overtime_alert").count
  end

  test "一度に80%と100%の両方を超えたら、両方を1回ずつ送る（80% → 100% の順）" do
    overtime!(nov(2), 360)
    overtime!(nov(3), 300)
    assert_equal [ 80, 100 ], check.map(&:level)
    assert_equal [ "警告ライン（10時間）の80%を超えました", "警告ライン（10時間）を超えました" ],
                 employee_alerts.map { |note| note.title.delete_prefix("2026年11月の残業が") }
  end

  test "残業が減って下回り、また超えても、同じ月度には送り直さない" do
    overtime!(nov(2), 300)
    day = overtime!(nov(3), 200)
    assert_equal [ 80 ], check.map(&:level)

    day.update!(clock_out_at: at(nov(3), 17)) # 修正で残業が減った（5:00）
    assert_empty check
    day.update!(clock_out_at: at(nov(3), 21)) # また超えた（9:00）
    assert_empty check
    assert_equal 1, employee_alerts.size
  end

  test "月度ごとに数える。10月度の警告を送っていても、11月度はまた80%から送る" do
    overtime!(Date.new(2026, 10, 5), 500)
    assert_equal [ 80 ], check(date: Date.new(2026, 10, 5)).map(&:level)
    assert_match "2026年10月の残業", employee_alerts.last.title

    overtime!(nov(2), 500)
    assert_equal [ [ "2026-11", 80 ] ], check.map { |alert| [ alert.period_key, alert.level ] }
    assert_equal 2, employee_alerts.size
  end

  test "締め済みの月度は判定しない" do
    overtime!(Date.new(2026, 10, 5), 700)
    MonthlyClosing.close!(year: 2026, month: 10, by: @admin)
    assert_empty check(date: Date.new(2026, 10, 5))
    assert_equal 0, Notification.count
  end

  test "管理者への通知は、有効な管理者全員（本人を除く）。管理者本人の残業は、本人向けの1件だけ" do
    admin2 = User.create!(name: "管理 二郎", email: "admin2@example.com", password: "password123", role: "admin", hired_on: Date.new(2021, 4, 1))
    User.create!(name: "管理 三郎", email: "admin3@example.com", password: "password123", role: "admin", hired_on: Date.new(2021, 4, 1),
                 active: false)

    overtime!(nov(2), 500)
    check
    assert_equal [ @admin.id, admin2.id ].sort, Notification.where(kind: "overtime_alert").where.not(recipient: @employee).pluck(:recipient_id).sort

    Notification.delete_all
    overtime!(nov(2), 500, user: @admin)
    check(@admin)
    notes = Notification.where(kind: "overtime_alert").to_a
    assert_equal [ @admin.id, admin2.id ].sort, notes.map(&:recipient_id).sort
    assert_equal attendances_path(month: "2026-11"), notes.find { |note| note.recipient_id == @admin.id }.path, "本人には勤怠履歴へのリンク"
    assert_equal admin_monthly_summary_path(@admin, month: "2026-11"), notes.find { |note| note.recipient_id == admin2.id }.path
  end

  test "無効な従業員は判定しない" do
    inactive = users(:inactive_employee)
    overtime!(nov(2), 700, user: inactive)
    assert_empty check(inactive)
    assert_equal 0, Notification.count
  end

  # ---- 判定のきっかけ ----

  test "退勤の打刻で判定する（勤務日の月度。日付をまたいだ退勤も出勤した日の月度）" do
    overtime!(nov(2), 480)
    travel_to at(nov(24), 9)
    TimeClock.new(@employee).clock_in!
    travel_to at(nov(24), 17, 30)
    attendance = TimeClock.new(@employee).clock_out!
    assert attendance.clocked_out?
    assert_equal [ 80 ], OvertimeAlert.where(user: @employee).pluck(:level)
    assert_equal 1, employee_alerts.size
  end

  test "打刻修正申請の承認で勤怠が変わったら判定する。却下では判定しない" do
    overtime!(nov(2), 480)
    request = @employee.attendance_correction_requests.new(target_date: nov(20), clock_in_time: "09:00", clock_out_time: "18:00",
                                                           reason: "打刻を忘れたため")
    assert request.submit
    rejected = ApprovalReview.new(approval_request: request, reviewer: @admin, decision: "reject", comment: "確認できないため")
    assert rejected.save
    assert_equal 0, OvertimeAlert.count

    request2 = @employee.attendance_correction_requests.new(target_date: nov(19), clock_in_time: "09:00", clock_out_time: "18:00",
                                                            reason: "打刻を忘れたため")
    assert request2.submit
    review = ApprovalReview.new(approval_request: request2, reviewer: @admin, decision: "approve")
    assert review.save
    assert_equal [ 80 ], OvertimeAlert.where(user: @employee).pluck(:level)
  end

  test "管理者の直接修正で判定する" do
    overtime!(nov(2), 480)
    editor = AttendanceRecordEditor.new(user: @employee, work_date: nov(20), editor: @admin, clock_in_time: "09:00",
                                        clock_out_time: "17:30", reason: "打刻漏れの修正", record_token: AttendanceRecordEditor::NO_RECORD_TOKEN)
    assert editor.save, editor.errors.full_messages.inspect
    assert_equal [ 80 ], OvertimeAlert.where(user: @employee).pluck(:level)
  end

  test "全員の今月度をまとめて判定できる（勤務ルールの変更のあと）" do
    overtime!(nov(2), 300, user: @employee)
    overtime!(nov(2), 200, user: @admin)
    assert_empty OvertimeAlert.check_all
    set_rules!(overtime_warning_hours: 4) # 80% = 3:12、100% = 4:00
    alerts = OvertimeAlert.check_all
    assert_equal [ [ @employee.id, 80 ], [ @employee.id, 100 ] ], alerts.select { |alert| alert.user_id == @employee.id }.map { |alert| [ alert.user_id, alert.level ] }
    assert_equal [ 80 ], alerts.select { |alert| alert.user_id == @admin.id }.map(&:level)
    assert_empty OvertimeAlert.check_all
  end

  # ---- 失敗しても元の処理は成功する ----

  test "判定に失敗しても（例外が起きても）、退勤は記録され、例外は外に出ない" do
    travel_to at(nov(24), 9)
    TimeClock.new(@employee).clock_in!
    travel_to at(nov(24), 18)
    MonthlyAttendance.stub(:for_user, ->(*, **) { raise "計算に失敗" }) do
      attendance = TimeClock.new(@employee).clock_out!
      assert attendance.clocked_out?
    end
    assert Attendance.find_by(user: @employee, work_date: nov(24)).clocked_out?
    assert_equal 0, OvertimeAlert.count
  end

  test "通知が作れなかったときは、警告の記録も残さない（次の判定で送り直せる）" do
    overtime!(nov(2), 500)
    Notification.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, "disk I/O error" }) do
      assert_empty check
    end
    assert_equal 0, OvertimeAlert.count
    assert_equal [ 80 ], check.map(&:level)
    assert_equal 1, employee_alerts.size
  end
end
