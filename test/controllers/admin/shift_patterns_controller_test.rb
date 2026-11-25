require "test_helper"

# シフトパターンの管理（F11）
class Admin::ShiftPatternsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @employee = users(:employee)
  end

  test "パターンを登録・一覧・変更・削除できる。変更・削除しても作ったシフトは変わらない" do
    sign_in_as @admin
    get admin_shift_patterns_path(week: "2026-11-23")
    assert_response :success
    assert_select "[data-testid='shift-patterns-empty']"
    assert_select "a.back-link[href='#{admin_shifts_path(week: '2026-11-23')}']"

    post admin_shift_patterns_path(week: "2026-11-23"), params: { shift_pattern: { name: "早番", start_time: "09:00", end_time: "18:00", break_minutes: "60" } }
    assert_redirected_to admin_shift_patterns_path(week: "2026-11-23")
    assert_equal "シフトパターン「早番」（9:00〜18:00・休憩60分）を登録しました。", flash[:notice]
    post admin_shift_patterns_path, params: { shift_pattern: { name: "夜勤", start_time: "22:00", end_time: "06:00", break_minutes: "60" } }
    pattern = ShiftPattern.find_by!(name: "早番")

    get admin_shift_patterns_path
    assert_select "[data-testid='shift-pattern-row']", 2
    assert_select "[data-testid='shift-pattern-row'] [data-column='range']", text: "22:00〜翌6:00"

    shift = Shift.create!(user: @employee, work_date: Date.current + 1, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    patch admin_shift_pattern_path(pattern), params: { shift_pattern: { name: "早番", start_time: "08:00", end_time: "17:00", break_minutes: "60" } }
    assert_redirected_to admin_shift_patterns_path
    assert_equal 480, pattern.reload.start_minute
    assert_equal "9:00〜18:00", shift.reload.range_label

    delete admin_shift_pattern_path(pattern)
    assert_not ShiftPattern.exists?(pattern.id)
    assert Shift.exists?(shift.id)
    delete admin_shift_pattern_path(pattern)
    assert_includes flash[:alert], "指定されたシフトパターンが見つかりません"
  end

  test "名前の重複・終了＝開始・休憩が長すぎる・数値でない休憩は登録できない" do
    ShiftPattern.create!(name: "早番", start_time: "9:00", end_time: "18:00", break_minutes: 60)
    sign_in_as @admin

    post admin_shift_patterns_path, params: { shift_pattern: { name: " 早番 ", start_time: "10:00", end_time: "10:00", break_minutes: "abc" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors", text: /パターン名はすでに使われています/
    assert_select ".form-errors", text: /終了時刻が開始時刻と同じです/
    assert_select ".form-errors", text: /休憩時間は数値（分）で入力してください/

    post admin_shift_patterns_path, params: { shift_pattern: { name: "短時間", start_time: "10:00", end_time: "11:00", break_minutes: "60" } }
    assert_select ".form-errors", text: /休憩時間は勤務時間（1:00）より短くしてください/
    post admin_shift_patterns_path
    assert_response :unprocessable_entity
    assert_equal 1, ShiftPattern.count
  end

  test "従業員ロールはパターンを管理できない" do
    sign_in_as @employee
    get admin_shift_patterns_path
    assert_redirected_to root_path
    post admin_shift_patterns_path, params: { shift_pattern: { name: "早番", start_time: "9:00", end_time: "18:00", break_minutes: "60" } }
    assert_equal 0, ShiftPattern.count
  end
end
