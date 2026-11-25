require "test_helper"

# 勤怠履歴（F5）で、休暇の期間内の休日（土日・祝日）の表示と、月の休暇日数の数え方をそろえる（スプリント 9.2 の評価の指摘 2）
class AttendancesLeaveDaysOffTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 25, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
  end

  teardown { travel_back }

  def approved_leave!(from, to, type:)
    leave = @employee.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: "full_day", reason: "私用")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  test "休暇の期間内の休日には、休暇のバッジではなく「休日（有給の期間中）」と出し、休暇の日の色にしない" do
    approved_leave!(Date.new(2026, 11, 20), Date.new(2026, 11, 24), type: "paid")
    sign_in_as @employee

    get attendances_path(month: "2026-11")
    assert_select "tr[data-date='2026-11-20'].history-row--leave [data-testid='day-leave'][data-leave-status=approved]", text: "有給（全日）"
    assert_select "tr[data-date='2026-11-24'] [data-testid='day-leave'][data-leave-status=approved]", text: "有給（全日）"
    %w[2026-11-21 2026-11-22 2026-11-23].each do |date|
      assert_select "tr[data-date='#{date}'] [data-testid='day-leave'][data-leave-status='day-off']", text: "休日（有給の期間中）"
      assert_select "tr[data-date='#{date}'] [data-leave-status=approved]", 0
      assert_select "tr[data-date='#{date}'].history-row--leave", 0
    end
    # バッジ（2日分）と月の合計（2日）がそろう
    assert_equal 2, css_select("[data-testid='day-leave'][data-leave-status=approved]").size
    assert_select "[data-testid='leave-totals']", text: /有給 2日/
  end

  test "休日だけの特別休暇（0日）は、バッジが休日の表示になり、月の休暇欄に「特別休暇 0日」と出る（「なし」にしない）" do
    approved_leave!(Date.new(2026, 11, 21), Date.new(2026, 11, 23), type: "special")
    sign_in_as @employee

    get attendances_path(month: "2026-11")
    assert_select "[data-testid='day-leave'][data-leave-status=approved]", 0
    assert_equal 3, css_select("[data-testid='day-leave'][data-leave-status='day-off']").size
    assert_select "tr[data-date='2026-11-23'] [data-testid='day-leave']", text: "休日（特別休暇の期間中）"
    assert_select "[data-testid='leave-totals']", text: /特別休暇 0日/
    assert_select "[data-testid='leave-totals']", text: /なし/, count: 0
  end

  test "祝日の勤務なしの行にも「勤務なし」を出す" do
    sign_in_as @employee
    get attendances_path(month: "2026-11")
    assert_select "tr[data-date='2026-11-03'].history-row--holiday .history-table__empty-label", text: "勤務なし"
  end
end
