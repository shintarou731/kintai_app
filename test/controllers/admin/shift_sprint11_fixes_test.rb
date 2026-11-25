require "test_helper"

# スプリント11の評価の指摘の修正（シフト作成）：
# - 半休の日に、シフトが半休の時間（午前半休＝〜12:00・午後半休＝13:00〜）と重なるかを判定して知らせる（入力画面・登録・割り当て・前週のコピー・マス）
# - パターンの割り当ての結果は、画面上部に重ねて出すメッセージ（トースト）で出す（ページの中に差し込まない）
# - 無効な従業員のシフトの画面は、入力欄と送信ボタンを押せない。保存できなかったときも、保存されている状態を出す
class Admin::ShiftSprint11FixesTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 25, 10, 0)
  WEEK = Date.new(2026, 11, 23)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    @inactive = users(:inactive_employee)
  end

  teardown { travel_back }

  def half_day_leave!(date, part)
    leave = @employee.leave_requests.new(target_date: date, end_date: date, leave_type: "paid", day_part: part, reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  def cell_selector(user, date)
    "td#shift_cell_#{user.id}_#{date.iso8601}"
  end

  test "半休の時間との重なり：午前半休は 12:00 より前に始まると重なり、午後半休は 13:00 より後に終わると重なる" do
    morning = half_day_leave!(Date.new(2026, 11, 26), "morning")
    afternoon = half_day_leave!(Date.new(2026, 11, 27), "afternoon")
    overlapping = lambda do |date, start_time, end_time|
      Shift.new(user: @employee, work_date: date, start_time: start_time, end_time: end_time, break_minutes: 0).overlapping_half_day_leaves
    end

    assert_equal [ morning ], overlapping.call(morning.target_date, "9:00", "18:00")
    assert_equal [ morning ], overlapping.call(morning.target_date, "11:59", "18:00")
    assert_empty overlapping.call(morning.target_date, "12:00", "18:00")
    assert_empty overlapping.call(morning.target_date, "22:00", "6:00")
    assert_equal [ afternoon ], overlapping.call(afternoon.target_date, "9:00", "18:00")
    assert_equal [ afternoon ], overlapping.call(afternoon.target_date, "9:00", "13:01")
    assert_empty overlapping.call(afternoon.target_date, "9:00", "13:00")
    assert_equal [ afternoon ], overlapping.call(afternoon.target_date, "22:00", "6:00")
  end

  test "半休と重なるシフトの登録は、保存したうえで注意を出す。マスに「半休と重なる」と出る" do
    half_day_leave!(Date.new(2026, 11, 26), "morning")
    sign_in_as @admin

    get new_admin_shift_path(user_id: @employee.id, date: "2026-11-26")
    assert_select "[data-testid='shift-half-leave-note']", text: /午前半休は 〜12:00 を休みとして扱います/
    assert_select "form[data-testid='shift-form'][data-shift-form-half-days-value*='\"from\":0']"

    post admin_shifts_path, params: { shift: { user_id: @employee.id, work_date: "2026-11-26", start_time: "9:00", end_time: "18:00", break_minutes: "60" } }
    assert_response :redirect
    assert_includes flash[:notice], "シフト（9:00〜18:00）が半休の時間（午前半休は〜12:00）と重なっています"

    get admin_shifts_path
    assert_select "#{cell_selector(@employee, Date.new(2026, 11, 26))} [data-testid='shift-cell-half-conflict']", "半休と重なる"
    shift = Shift.find_by!(user: @employee, work_date: Date.new(2026, 11, 26))
    get edit_admin_shift_path(shift)
    assert_select "[data-testid='shift-half-leave-note'][data-overlapping='true'] [data-testid='shift-half-leave-overlap']", text: /9:00〜18:00/

    # 重ならない時間に直すと、注意は出ない
    patch admin_shift_path(shift), params: { shift: { start_time: "13:00", end_time: "18:00", break_minutes: "0", lock_version: shift.lock_version } }
    assert_not_includes flash[:notice], "重なっています"
    get admin_shifts_path
    assert_select "#{cell_selector(@employee, Date.new(2026, 11, 26))} [data-testid='shift-cell-half-conflict']", count: 0
  end

  test "パターンの割り当て：結果はトーストで出し、半休と重なるときは注意として知らせる。ページ上部のメッセージは出さない" do
    early = ShiftPattern.create!(name: "早番", start_time: "9:00", end_time: "18:00", break_minutes: 60)
    late = ShiftPattern.create!(name: "遅番", start_time: "13:00", end_time: "22:00", break_minutes: 60)
    half_day_leave!(Date.new(2026, 11, 26), "morning")
    sign_in_as @admin
    get admin_shifts_path(week: WEEK.iso8601, pattern: early.id)

    post admin_shifts_assignments_path, params: { user_id: @employee.id, date: "2026-11-26", pattern_id: early.id, lock_version: "" }
    assert_nil flash[:notice]
    assert_includes flash[:toast_alert], "半休の時間（午前半休は〜12:00）と重なっています"
    follow_redirect!
    assert_select "[data-testid='toast'] .flash--alert", text: /割り当てました（下書き）/
    assert_select ".flash-area", count: 0

    shift = Shift.find_by!(user: @employee, work_date: Date.new(2026, 11, 26))
    post admin_shifts_assignments_path, params: { user_id: @employee.id, date: "2026-11-26", pattern_id: late.id, lock_version: shift.lock_version }
    assert_equal "11/26(木) 従業 花子 さんに「遅番」（13:00〜22:00）を割り当てました（下書き）。", flash[:toast_notice]
    follow_redirect!
    assert_select "[data-testid='toast'][data-toast-auto-hide-value='true'] .flash--notice", text: /「遅番」/
  end

  test "前週のコピー：半休の時間と重なるマスの件数を、確認と結果のメッセージで知らせる（コピーはする）" do
    Shift.create!(user: @employee, work_date: WEEK - 7 + 2, start_time: "17:00", end_time: "22:00", break_minutes: 0)
    Shift.create!(user: @employee, work_date: WEEK - 7 + 3, start_time: "9:00", end_time: "13:00", break_minutes: 0)
    half_day_leave!(WEEK + 2, "afternoon")
    half_day_leave!(WEEK + 3, "afternoon")
    sign_in_as @admin

    get admin_shifts_path
    assert_select "form[data-testid='copy-form'][data-turbo-confirm*='シフトが半休の時間（午前半休は〜12:00・午後半休は13:00〜）と重なるマス 1件']"
    post admin_shifts_copy_path, params: { week: WEEK.iso8601 }
    assert_includes flash[:notice], "2件 コピーしました"
    assert_includes flash[:notice], "と重なるマス 1件 はコピーしました。シフト表で「半休と重なる」と出ているマスの時間を確かめてください。"
    assert Shift.exists?(user: @employee, work_date: WEEK + 2)
  end

  test "無効な従業員のシフトの画面：入力欄と保存のボタンは押せず、保存できなかったときも保存されている状態を出す" do
    shift = Shift.new(user: @inactive, work_date: WEEK + 1, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    shift.save!(validate: false)
    shift.publish_draft!(now: NOW)
    sign_in_as @admin

    get edit_admin_shift_path(shift)
    assert_select "[data-testid='shift-locked-note']"
    assert_select "fieldset[data-testid='shift-form-fields'][disabled]"
    assert_select "input[type='submit'][data-testid='shift-submit'][disabled]"
    assert_select "[data-testid='shift-delete']"

    patch admin_shift_path(shift), params: { shift: { start_time: "10:00", end_time: "19:00", break_minutes: "60", lock_version: shift.lock_version } }
    assert_response :unprocessable_entity
    assert_select "[data-testid='shift-publication-state'] [data-testid='shift-state'][data-state='published']"
    assert_select "[data-testid='shift-publication-state']", text: /公開済みです/
    assert_select "form[data-turbo-confirm*='（9:00〜18:00）を削除します']"
    assert_equal "9:00〜18:00", shift.reload.range_label
  end
end
