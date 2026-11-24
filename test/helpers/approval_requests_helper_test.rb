require "test_helper"

class ApprovalRequestsHelperTest < ActionView::TestCase
  include ApplicationHelper
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @employee = users(:employee)
    travel_to NOW
  end

  teardown { travel_back }

  def open_ended_correction
    request = @employee.attendance_correction_requests.new(target_date: NOW.to_date, clock_in_time: "09:00", clock_out_time: "",
                                                           reason: "出勤の打刻を忘れました")
    assert request.submit, request.errors.full_messages.inspect
    request
  end

  def row(rows, label)
    rows.find { |item| item[:label] == label }
  end

  test "記録が無い日に退勤を空欄で申請したとき、退勤の行（未打刻→空欄）は変更扱いにしない" do
    rows = correction_comparison_rows(open_ended_correction)

    clock_out = row(rows, "退勤")
    assert_equal [ "未打刻", "空欄（勤務中）" ], [ clock_out[:current], clock_out[:requested] ]
    assert_not clock_out[:changed]
    assert row(rows, "出勤")[:changed]
  end

  test "勤務中の記録（退勤なし）に退勤を空欄で申請したときも、退勤の行は変更扱いにしない" do
    @employee.attendances.create!(work_date: NOW.to_date, clock_in_at: NOW.change(hour: 9, min: 30))
    rows = correction_comparison_rows(open_ended_correction)

    assert_not row(rows, "退勤")[:changed]
    assert row(rows, "出勤")[:changed], "出勤 09:30 → 09:00 は変更"
  end

  test "退勤がある記録を、退勤を空欄にする申請と比べると変更扱いになる" do
    travel_to(NOW.change(hour: 23)) do
      @employee.attendances.create!(work_date: NOW.to_date, clock_in_at: NOW.change(hour: 9), clock_out_at: NOW.change(hour: 18))
      request = @employee.attendance_correction_requests.new(target_date: NOW.to_date, clock_in_time: "09:00", clock_out_time: "19:00",
                                                             reason: "退勤時刻の誤り")
      assert request.submit, request.errors.full_messages.inspect
      assert row(correction_comparison_rows(request), "退勤")[:changed]
    end
  end

  test "休暇の日数は「3日」「0.5日」の形で、土日・祝日を含む期間は「土日祝を除く」と添える" do
    leave = LeaveRequest.new(target_date: Date.new(2026, 11, 26), end_date: Date.new(2026, 11, 30), leave_type: "paid", day_part: "full_day")
    assert_equal "3日・土日祝を除く", leave_days_label(leave)
    assert_equal "有給休暇・全日（3日・土日祝を除く）", leave_summary(leave)

    leave.assign_attributes(end_date: Date.new(2026, 11, 26), day_part: "morning")
    assert_equal "0.5日", leave_days_label(leave)
    assert_equal "1.5日", format_leave_days(3/2r)
    assert_equal "2026年11月26日(木)〜11月30日(月)",
                 approval_request_long_target_label(LeaveRequest.new(target_date: Date.new(2026, 11, 26), end_date: Date.new(2026, 11, 30)))
  end

  test "祝日を含む休暇は、日数と除いた休日（祝日名つき）を示す" do
    leave = LeaveRequest.new(target_date: Date.new(2026, 11, 20), end_date: Date.new(2026, 11, 24), leave_type: "paid", day_part: "full_day")
    assert_equal "2日・土日祝を除く", leave_days_label(leave)
    assert_equal "11/21(土)、11/22(日)、11/23(月) 勤労感謝の日", leave_days_off_label(leave)

    weekdays = LeaveRequest.new(target_date: Date.new(2026, 11, 24), end_date: Date.new(2026, 11, 25), leave_type: "paid", day_part: "full_day")
    assert_equal "2日", leave_days_label(weekdays)
    assert_nil leave_days_off_label(weekdays)
  end

  test "休暇の入力画面に渡す祝日は、今日の前後1年の分（日付の文字列 => 祝日名）" do
    holidays = leave_form_holidays(Date.new(2026, 11, 25))
    assert_equal "勤労感謝の日", holidays["2026-11-23"]
    assert_equal "振替休日", holidays["2027-03-22"]
    assert_equal "元日", holidays["2026-01-01"]
    assert_nil holidays["2025-11-24"], "1年より前（2025-11-24 の振替休日）は含めない"
    assert_nil holidays["2026-11-24"]
  end
end
