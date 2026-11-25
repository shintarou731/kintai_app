require "test_helper"

# 締め済み（F14）の月度の勤怠は、どの書き込みの入口からも変えられない（ClosedPeriodGuard）。
# 打刻修正申請（申請・承認）、休暇申請（申請・承認・取消申請の申請と承認）、管理者の直接修正・削除、管理者の休暇の直接取消、打刻。
# 承認待ちのまま締めた申請を、後から承認しようとした場合も止める（却下・取り下げはできる）。
class ClosedPeriodGuardTest < ActiveSupport::TestCase
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

  def close_november!
    MonthlyClosing.close!(year: 2026, month: 11, by: @admin)
  end

  def correction(date, clock_out: "18:00")
    @employee.attendance_correction_requests.new(target_date: date, clock_in_time: "09:00", clock_out_time: clock_out, reason: "打刻忘れ")
  end

  def leave(from, to, status: "pending", type: "special")
    record = LeaveRequest.new(user: @employee, leave_type: type, target_date: from, end_date: to, reason: "私用", status: status)
    record.save!(validate: false)
    record
  end

  def review(request, decision, comment: nil)
    ApprovalReview.new(approval_request: ApprovalRequest.find(request.id), reviewer: @admin, decision: decision, comment: comment)
  end

  test "締めが無ければ判定はすべて nil／false" do
    assert_nil ClosedPeriodGuard.closing_overlapping(nov(1), nov(30))
    assert_not ClosedPeriodGuard.closed?(nov(10))
    close_november!
    assert_equal "2026年11月", ClosedPeriodGuard.closed_period_label(nov(30), Date.new(2026, 12, 1))
    assert_nil ClosedPeriodGuard.closing_overlapping(Date.new(2026, 12, 1), Date.new(2026, 12, 3))
    MonthlyClosing.active.first.reopen!(by: @admin)
    assert_not ClosedPeriodGuard.closed?(nov(10))
  end

  test "打刻修正申請：締め済みの日は申請できない。承認待ちのまま締めた申請は承認できず、却下はできる" do
    pending = correction(nov(10))
    assert pending.submit
    close_november!

    fresh = correction(nov(11))
    assert_not fresh.submit
    assert_match "締め済みの月度（2026年11月：11/1(日)〜11/30(月)）に含まれるため、修正申請できません", fresh.errors.full_messages.join
    assert correction(Date.new(2026, 12, 1)).submit, "12月の日は申請できる"

    approval = review(pending, "approve")
    assert_not approval.save
    assert_match "締め済みの月度", approval.errors.full_messages.join
    assert pending.reload.pending?
    assert_nil Attendance.find_by(user: @employee, work_date: nov(10))
    assert_includes pending.approval_blockers.join, "却下はできます"

    assert review(pending, "reject", comment: "締め済みのため").save
    assert pending.reload.rejected?
  end

  test "休暇申請：締め済みの月度に1日でもかかる休暇は申請できず、承認待ちのまま締めた休暇は承認できない" do
    pending = leave(nov(12), nov(12))
    close_november!

    [ [ nov(30), nov(30) ], [ nov(30), Date.new(2026, 12, 1) ] ].each do |from, to|
      request = @employee.leave_requests.new(leave_type: "special", target_date: from, end_date: to, reason: "私用")
      assert_not request.submit, "#{from}〜#{to}"
      assert_match "締め済みの月度（2026年11月", request.errors.full_messages.join
    end
    assert @employee.leave_requests.new(leave_type: "special", target_date: Date.new(2026, 12, 1), end_date: Date.new(2026, 12, 1),
                                        reason: "私用").submit

    approval = review(pending, "approve")
    assert_not approval.save
    assert_match "締め済みの月度", approval.errors.full_messages.join
    assert pending.reload.pending?
    assert @employee.leave_requests.find(pending.id).withdraw, "取り下げはできる"
  end

  test "休暇の取消申請：締め済みの月度にかかる休暇の取消申請は承認できない。管理者の直接取消もできない" do
    approved = leave(nov(20), nov(20), status: "approved")
    cancellation = LeaveCancellationRequest.new(user: @employee, leave_request: approved, target_date: approved.target_date, reason: "予定が変わった")
    cancellation.save!(validate: false)
    close_november!

    approval = review(cancellation, "approve")
    assert_not approval.save
    assert_match "締め済みの月度", approval.errors.full_messages.join
    assert approved.reload.effective?

    direct = LeaveDirectCancellation.new(leave_request: approved, admin: @admin, reason: "本人から連絡")
    assert_not direct.save
    assert_match "締め済みの月度", direct.errors.full_messages.join
    assert approved.reload.effective?
  end

  test "管理者の直接修正・作成・削除：締め済みの月度の日はどれもできない" do
    attendance = Attendance.create!(user: @employee, work_date: nov(10), clock_in_at: at(nov(10), 9), clock_out_at: at(nov(10), 18))
    close_november!

    editor = AttendanceRecordEditor.new(user: @employee, work_date: nov(10), editor: @admin).prefill
    editor.clock_out_time = "19:00"
    editor.reason = "退勤の誤り"
    assert_not editor.save
    assert_match "締め済みの月度（2026年11月", editor.errors.full_messages.join
    assert_equal at(nov(10), 18), attendance.reload.clock_out_at

    creator = AttendanceRecordEditor.new(user: @employee, work_date: nov(11), editor: @admin, clock_in_time: "09:00",
                                         clock_out_time: "18:00", reason: "打刻忘れ")
    assert_not creator.save
    assert_nil Attendance.find_by(user: @employee, work_date: nov(11))

    remover = AttendanceRecordEditor.new(user: @employee, work_date: nov(10), editor: @admin, reason: "誤打刻")
    assert_not remover.destroy_record
    assert Attendance.exists?(attendance.id)
    assert_equal 0, AttendanceEdit.count
  end

  test "打刻：締め済みの月度の勤務日の勤務には退勤・休憩を記録できず、今日の出勤はできる" do
    travel_to at(nov(30), 22, 0)
    TimeClock.new(@employee).clock_in!
    travel_to at(Date.new(2026, 12, 1), 0, 30)
    close_november!

    clock = TimeClock.new(@employee)
    assert_equal :not_started, clock.state
    assert_equal nov(30), clock.closed_open_attendance.work_date
    error = assert_raises(TimeClock::Error) { clock.clock_out! }
    assert_match "11/30(月) の勤務は締め済みの月度（2026年11月：11/1(日)〜11/30(月)）に含まれるため、退勤を記録できません", error.message
    assert_raises(TimeClock::Error, match: /休憩開始を記録できません/) { TimeClock.new(@employee).start_break! }
    assert_nil Attendance.find_by!(user: @employee, work_date: nov(30)).clock_out_at

    TimeClock.new(@employee).clock_in!
    assert Attendance.exists?(user: @employee, work_date: Date.new(2026, 12, 1))
  end

  test "打刻：今日が締め済みの月度に入る場合（時計を過去に戻した開発環境など）は出勤できない" do
    close_november!
    travel_to at(nov(16), 9, 0)
    error = assert_raises(TimeClock::Error) { TimeClock.new(@employee).clock_in! }
    assert_match "出勤を記録できません", error.message
    assert_not Attendance.exists?(user: @employee, work_date: nov(16))
  end

  test "締めを解除すると、また申請・承認・直接修正ができる" do
    pending = correction(nov(10))
    assert pending.submit
    close_november!.reopen!(by: @admin)

    assert review(pending, "approve").save
    assert Attendance.exists?(user: @employee, work_date: nov(10))
    assert correction(nov(11)).submit
  end
end
