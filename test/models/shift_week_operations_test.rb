require "test_helper"

# シフトの週単位の操作（F11）：前週のコピー・公開・パターンの割り当て・シフト表の集計
class ShiftWeekOperationsTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-25 は水曜日。今週は 11/23（月・勤労感謝の日）〜11/29（日）、前週は 11/16〜11/22
  NOW = Time.zone.local(2026, 11, 25, 10, 0)
  WEEK = Date.new(2026, 11, 23)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    @inactive = users(:inactive_employee)
  end

  teardown { travel_back }

  def shift!(date, start_time = "9:00", end_time = "18:00", user: @employee, break_minutes: 60)
    shift = Shift.new(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: break_minutes,
                      created_by: @admin, updated_by: @admin)
    shift.save!(validate: user.active?)
    shift
  end

  def approved_leave!(from, to = from, part: "full_day", user: @employee)
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: "special", day_part: part, reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  def copy
    ShiftWeekCopy.new(week_start: WEEK, admin: @admin)
  end

  test "前週のシフトを7日後の同じ曜日にコピーする（下書き）" do
    shift!(WEEK - 7, "9:00", "18:00")
    shift!(WEEK - 5, "22:00", "6:00")
    shift!(WEEK - 7, "13:00", "22:00", user: @admin)

    assert_equal 3, copy.plan.copied
    operation = copy
    assert operation.save, operation.errors.full_messages.inspect
    assert_equal 3, operation.result.copied

    copied = Shift.on_dates(WEEK..(WEEK + 6)).order(:work_date, :user_id).to_a
    assert_equal [ [ @admin.id, WEEK, "13:00〜22:00" ], [ @employee.id, WEEK, "9:00〜18:00" ], [ @employee.id, WEEK + 2, "22:00〜翌6:00" ] ],
                 copied.map { |shift| [ shift.user_id, shift.work_date, shift.range_label ] }.sort_by { |row| [ row[1], row[0] ] }
    assert copied.all? { |shift| shift.state == :draft }
  end

  test "すでにシフトがあるマスは上書きせず、全日の休暇の日と無効な従業員のシフトもコピーしない" do
    shift!(WEEK - 7)
    shift!(WEEK - 6)
    shift!(WEEK - 5)
    shift!(WEEK - 7, user: @inactive)
    existing = shift!(WEEK, "10:00", "15:00")
    approved_leave!(WEEK + 1)

    plan = copy.plan
    assert_equal [ 1, 1, 1, 1 ], [ plan.copied, plan.existing, plan.on_leave, plan.inactive ]

    operation = copy
    assert operation.save
    assert_equal "10:00〜15:00", existing.reload.range_label, "すでにあるシフトは上書きしない"
    assert_not Shift.exists?(user: @employee, work_date: WEEK + 1)
    assert Shift.exists?(user: @employee, work_date: WEEK + 2)
    assert_not Shift.exists?(user: @inactive, work_date: WEEK)
  end

  test "削除予定のマスは空いているものとしてコピーする（削除を取りやめて前週の内容にする）" do
    shift!(WEEK - 7, "13:00", "22:00")
    removing = shift!(WEEK)
    removing.publish_draft!(now: NOW)
    removing.reload.remove!(by: @admin)

    assert copy.save
    removing.reload
    assert removing.live?
    assert_equal "13:00〜22:00", removing.range_label
    assert_equal :changed, removing.state
  end

  test "コピーできるシフトが無ければ、何も作らずに理由を返す" do
    operation = copy
    assert_not operation.save
    assert_includes operation.errors.full_messages.join, "前週（11/16〜11/22）には、コピーできるシフトがありません"

    shift!(WEEK - 7)
    shift!(WEEK)
    operation = copy
    assert_not operation.save
    assert_includes operation.errors.full_messages.join, "すでにシフトがあるマス 1件"
  end

  test "公開：未公開・変更・削除予定をまとめて反映し、件数を記録する。無効な従業員のシフトも公開する" do
    added = shift!(WEEK)
    changed = shift!(WEEK + 1)
    removed = shift!(WEEK + 2)
    untouched = shift!(WEEK + 3)
    inactive = shift!(WEEK, user: @inactive)
    [ changed, removed, untouched ].each { |shift| shift.publish_draft!(now: NOW - 1.day) }
    changed.reload.update!(start_time: "10:00")
    removed.reload.remove!(by: @admin)
    other_week = shift!(WEEK + 7)

    publication = ShiftWeekPublication.new(week_start: WEEK, admin: @admin)
    assert publication.save, publication.errors.full_messages.inspect
    record = publication.record
    assert_equal [ 2, 1, 1 ], [ record.added_count, record.changed_count, record.removed_count ]
    assert_equal "追加 2件・変更 1件・削除 1件", record.summary

    assert_equal :published, added.reload.state
    assert_equal :published, inactive.reload.state
    assert_equal "10:00〜18:00", changed.reload.published_range_label
    assert_equal NOW, changed.revised_at
    assert_nil added.revised_at
    assert_not Shift.exists?(removed.id)
    assert_equal NOW - 1.day, untouched.reload.published_at
    assert_equal :draft, other_week.reload.state, "他の週は公開しない"
  end

  test "公開する変更が無ければ公開しない" do
    publication = ShiftWeekPublication.new(week_start: WEEK, admin: @admin)
    assert_not publication.save
    assert_includes publication.errors.full_messages.join, "この週には公開する変更がありません"
    assert_equal 0, ShiftPublication.count
  end

  test "パターンの割り当て：空いたマスに登録し、シフトがあるマスは置き換え、全日の休暇の日は割り当てない" do
    early = ShiftPattern.create!(name: "早番", start_time: "9:00", end_time: "18:00", break_minutes: 60)
    late = ShiftPattern.create!(name: "遅番", start_time: "13:00", end_time: "22:00", break_minutes: 60)

    assignment = ShiftAssignment.new(user: @employee, date: WEEK + 1, pattern: early, admin: @admin)
    assert assignment.save, assignment.errors.full_messages.inspect
    shift = Shift.find_by!(user: @employee, work_date: WEEK + 1)
    assert_equal "9:00〜18:00", shift.range_label

    same = ShiftAssignment.new(user: @employee, date: WEEK + 1, pattern: early, admin: @admin, expected_lock_version: shift.lock_version)
    assert same.save
    assert same.unchanged?

    replace = ShiftAssignment.new(user: @employee, date: WEEK + 1, pattern: late, admin: @admin, expected_lock_version: shift.lock_version.to_s)
    assert replace.save
    assert_equal "13:00〜22:00", shift.reload.range_label

    approved_leave!(WEEK + 2)
    on_leave = ShiftAssignment.new(user: @employee, date: WEEK + 2, pattern: early, admin: @admin)
    assert_not on_leave.save
    assert_includes on_leave.errors.full_messages.join, "休暇（特別休暇（全日））の日のため、割り当てませんでした"
    assert_not Shift.exists?(user: @employee, work_date: WEEK + 2)
  end

  test "パターンの割り当て：画面で見ていた後に他の管理者がマスを変えていたら、割り当てない" do
    early = ShiftPattern.create!(name: "早番", start_time: "9:00", end_time: "18:00", break_minutes: 60)
    shift = shift!(WEEK + 1, "10:00", "16:00")

    as_empty = ShiftAssignment.new(user: @employee, date: WEEK + 1, pattern: early, admin: @admin, expected_lock_version: nil)
    assert_not as_empty.save
    assert_equal [ ShiftAssignment::CONFLICT_MESSAGE ], as_empty.errors.full_messages

    stale = ShiftAssignment.new(user: @employee, date: WEEK + 1, pattern: early, admin: @admin, expected_lock_version: shift.lock_version - 1)
    assert_not stale.save
    assert_equal "10:00〜16:00", shift.reload.range_label
  end

  test "シフト表：無効な従業員は表に出さず人数にも数えない。休暇・祝日・週の状態が分かる" do
    shift!(WEEK)
    shift!(WEEK, user: @admin)
    shift!(WEEK, user: @inactive)
    removing = shift!(WEEK + 1)
    removing.publish_draft!(now: NOW)
    removing.reload.remove!(by: @admin)
    approved_leave!(WEEK + 2)
    approved_leave!(WEEK + 3, part: "afternoon")

    board = ShiftBoard.new(week_start: WEEK + 2, today: Date.current)
    assert_equal WEEK, board.week_start
    assert_not_includes board.users, @inactive
    assert_equal 2, board.count_on(WEEK)
    assert_equal 0, board.count_on(WEEK + 1)
    assert_equal 1, board.inactive_shifts.size
    assert_equal "勤労感謝の日", board.holiday_name(WEEK)
    assert_equal :holiday, board.day_kind(WEEK)
    assert_equal 480, board.weekly_minutes(@employee)
    assert board.cell(@employee, WEEK + 2).full_day_leave
    assert_equal 1, board.cell(@employee, WEEK + 3).half_day_leaves.size
    assert_equal :removing, board.cell(@employee, WEEK + 1).removing_shift.state
    assert_equal :changed, board.status
    assert_equal({ added: 3, changed: 0, removed: 1 }, board.pending_counts)
  end

  test "週の指定：その日を含む週の月曜日。解釈できない・範囲外なら nil" do
    assert_equal WEEK, ShiftBoard.parse_week("2026-11-29")
    assert_equal Date.new(2026, 11, 30), ShiftBoard.parse_week("2026-11-30")
    assert_nil ShiftBoard.parse_week("abc")
    assert_nil ShiftBoard.parse_week("2026-02-30")
    assert_nil ShiftBoard.parse_week("2028-01-03")
    assert_nil ShiftBoard.parse_week("2025-11-16")
    assert_equal Date.new(2025, 11, 24), ShiftBoard.parse_week("2025-11-25")
  end
end
