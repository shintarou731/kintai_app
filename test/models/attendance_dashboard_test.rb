require "test_helper"

# 管理者のダッシュボード（F13。AttendanceDashboard）：今日の状態の判定・人数・遅れ・退勤漏れ・残業の警告。時刻はすべて固定する
class AttendanceDashboardTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-25（水）10:00
  NOW = Time.zone.local(2026, 11, 25, 10, 0)
  TODAY = NOW.to_date
  YESTERDAY = TODAY - 1

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    @inactive = users(:inactive_employee)
    @sequence = 0
  end

  teardown { travel_back }

  def member!(name = nil)
    @sequence += 1
    User.create!(name: name || "メンバー#{@sequence}", email: "member#{@sequence}@example.com", password: "password123",
                 role: "employee", hired_on: Date.new(2024, 4, 1))
  end

  def at(date, hour, minute = 0, second = 0)
    Time.zone.local(date.year, date.month, date.day, hour, minute, second)
  end

  def shift!(user, date = TODAY, start_time = "9:00", end_time = "18:00", publish: true)
    shift = Shift.new(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: 60)
    shift.save!(validate: user.active?)
    shift.publish_draft!(now: NOW - 2.days) if publish
    shift
  end

  def attendance!(user, clock_in_at, clock_out_at = nil, date: clock_in_at.to_date)
    Attendance.create!(user: user, work_date: date, clock_in_at: clock_in_at, clock_out_at: clock_out_at)
  end

  def approved_leave!(user, date = TODAY, part: "full_day")
    leave = user.leave_requests.new(target_date: date, end_date: date, leave_type: "paid", day_part: part, reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW - 3.days)
    leave
  end

  def dashboard(now: NOW, rules: WorkRules.new, admin: @admin)
    AttendanceDashboard.new(admin: admin, rules: rules, now: now)
  end

  def row_for(board, user)
    board.rows.find { |row| row.user == user }
  end

  test "状態の判定：勤務中・休憩中・退勤済み・未出勤・休暇と、状態ごとの人数（無効な従業員は出さない）" do
    working = member!
    shift!(working)
    attendance!(working, at(TODAY, 8, 55))

    on_break = member!
    record = attendance!(on_break, at(TODAY, 8, 0))
    record.breaks.create!(started_at: at(TODAY, 9, 50))

    finished = member!
    attendance!(finished, at(TODAY, 5, 0), at(TODAY, 9, 30))

    on_leave = member!
    shift!(on_leave)
    approved_leave!(on_leave)

    worked_on_leave = member!
    approved_leave!(worked_on_leave)
    attendance!(worked_on_leave, at(TODAY, 9, 0))

    attendance!(@inactive, at(TODAY, 9, 0))

    board = dashboard
    assert_equal :working, row_for(board, working).state
    assert_equal :on_break, row_for(board, on_break).state
    assert_equal :finished, row_for(board, finished).state
    assert_equal :on_leave, row_for(board, on_leave).state
    assert_not row_for(board, on_leave).late?, "休暇の人は遅れにしない"
    assert_equal :working, row_for(board, worked_on_leave).state, "休暇の日でも出勤していれば打刻の状態で数える"
    assert_equal 1, row_for(board, worked_on_leave).leaves.size
    assert_equal :not_started, row_for(board, @employee).state
    assert_equal :not_started, row_for(board, @admin).state, "管理者も一覧に入る"
    assert_nil row_for(board, @inactive), "無効な従業員は出さない"

    assert_equal({ working: 2, on_break: 1, finished: 1, not_started: 2, on_leave: 1 }, board.counts)
    assert_equal board.rows.size, board.counts.values.sum
    assert_equal 0, board.late_count
  end

  test "遅れ：シフトの開始を1分過ぎても出勤していない人（ShiftCheck と同じ。9:59 開始は 10:00 ではまだ遅れにしない）" do
    late = member!
    shift!(late, TODAY, "9:00", "18:00")
    boundary = member!
    shift!(boundary, TODAY, "9:59", "18:00")
    just_late = member!
    shift!(just_late, TODAY, "9:58", "18:00")
    upcoming = member!
    shift!(upcoming, TODAY, "13:00", "22:00")
    draft_only = member!
    shift!(draft_only, TODAY, "9:00", "18:00", publish: false)

    board = dashboard
    assert row_for(board, late).late?
    assert_equal :not_started, row_for(board, late).state
    assert_equal :not_clocked_in, row_for(board, late).late_check.status
    assert_not row_for(board, boundary).late?, "開始から1分（許容範囲）はまだ遅れにしない"
    assert row_for(board, just_late).late?, "開始から2分で遅れ"
    assert_not row_for(board, upcoming).late?
    assert_not row_for(board, draft_only).late?, "下書きのシフトでは判定しない"
    assert_equal 2, board.late_count
    assert_equal [ late, just_late ].sort_by(&:id), board.sorted_rows.first(2).map(&:user).sort_by(&:id), "遅れの人を表の先頭に出す"

    # シフトの終了を過ぎても出勤が無い（ShiftCheck の欠勤）も、今日の「未出勤（遅れ）」にする
    evening = dashboard(now: at(TODAY, 18, 30))
    assert row_for(evening, late).late?
    assert_equal :absent, row_for(evening, late).late_check.status

    # 出勤すれば遅れではなくなり、遅刻の印が付く
    attendance!(late, at(TODAY, 9, 12))
    after = dashboard
    assert_not row_for(after, late).late?
    assert_equal :working, row_for(after, late).state
    assert_equal 12, row_for(after, late).today_check.late_minutes
  end

  test "半休：午前半休は 12:00 まで「休暇」、13:02 に出勤していなければ遅れ。午後半休は朝のシフトに来なければ遅れ、13:00 から「休暇」" do
    morning = member!
    shift!(morning)
    approved_leave!(morning, part: "morning")
    afternoon = member!
    shift!(afternoon)
    approved_leave!(afternoon, part: "afternoon")
    afternoon_worked = member!
    shift!(afternoon_worked)
    approved_leave!(afternoon_worked, part: "afternoon")
    attendance!(afternoon_worked, at(TODAY, 9, 0), at(TODAY, 12, 0))

    board = dashboard
    assert_equal :on_leave, row_for(board, morning).state
    assert_not row_for(board, morning).late?
    assert row_for(board, afternoon).late?, "午後半休でも、午前のシフトに来ていなければ遅れ"

    lunch = dashboard(now: at(TODAY, 12, 30))
    assert_equal :not_started, row_for(lunch, morning).state, "昼休み（12:00〜13:00）は休暇の時間ではない"
    assert_not row_for(lunch, morning).late?

    assert row_for(dashboard(now: at(TODAY, 13, 2)), morning).late?, "午前半休の出勤の基準は 13:00（13:02 で遅れ）"
    assert_not row_for(dashboard(now: at(TODAY, 13, 1)), morning).late?

    no_shift_afternoon = member!
    approved_leave!(no_shift_afternoon, part: "afternoon")
    later = dashboard(now: at(TODAY, 14, 0))
    assert_equal :on_leave, row_for(later, no_shift_afternoon).state, "午後半休の時間帯（13:00〜）で打刻が無ければ休暇"
    assert_equal :finished, row_for(later, afternoon_worked).state
  end

  test "日付をまたぐ勤務：前日から勤務中なら「勤務中」、今日退勤した夜勤明けは「退勤済み」" do
    night = member!
    attendance!(night, at(YESTERDAY, 22, 0))
    night_done = member!
    attendance!(night_done, at(YESTERDAY, 22, 0), at(TODAY, 6, 0))
    yesterday_only = member!
    attendance!(yesterday_only, at(YESTERDAY, 9, 0), at(YESTERDAY, 18, 0))

    board = dashboard
    assert_equal :working, row_for(board, night).state
    assert row_for(board, night).overnight?
    assert_equal :finished, row_for(board, night_done).state
    assert row_for(board, night_done).overnight?
    assert_equal :not_started, row_for(board, yesterday_only).state, "前日のうちに退勤した人は、今日はまだ未出勤"
    assert_nil row_for(board, yesterday_only).attendance

    # 出勤から24時間を過ぎた退勤漏れの勤務は、今日の勤務としては扱わない（ホーム画面と同じ）
    later = dashboard(now: at(TODAY, 22, 1))
    assert_equal :not_started, row_for(later, night).state
  end

  test "前日に始まる日付をまたぐシフトの途中：0:30 にまだ出勤していなければ遅れ、出勤すれば勤務中" do
    late = member!
    shift!(late, YESTERDAY, "22:00", "6:00")
    came = member!
    shift!(came, YESTERDAY, "22:00", "6:00")
    attendance!(came, at(TODAY, 0, 20))

    board = dashboard(now: at(TODAY, 0, 30))
    assert row_for(board, late).late?
    assert_equal row_for(board, late).previous_check, row_for(board, late).late_check
    assert_equal :working, row_for(board, came).state
    assert_not row_for(board, came).late?
    assert_equal "22:00〜翌6:00", row_for(board, came).previous_shift.published_range_label

    # シフトが終わった後は、前日のシフトでは判定しない（今日のシフトが無ければ、ただの未出勤）
    morning = dashboard(now: at(TODAY, 7, 0))
    assert_not row_for(morning, late).late?
    assert_nil row_for(morning, late).previous_check
  end

  test "シフトの開始前に退勤した勤務は「退勤済み」で、遅れにも早退にもしない" do
    user = member!
    shift!(user, TODAY, "17:00", "22:00")
    attendance!(user, at(TODAY, 0, 24, 10), at(TODAY, 0, 24, 40))

    row = row_for(dashboard, user)
    assert_equal :finished, row.state
    assert_not row.late?
    assert_not row.today_check.early_leave?
  end

  test "承認待ちの件数：この管理者が処理できる件数（ナビのバッジと同じ）と全件" do
    admin2 = User.create!(name: "管理 二郎", email: "admin2@example.com", password: "password123", role: "admin", hired_on: Date.new(2021, 4, 1))
    [ @employee, @admin, @admin ].each_with_index do |user, index|
      request = user.attendance_correction_requests.new(target_date: Date.new(2026, 11, 20 + index), clock_in_time: "09:00",
                                                        clock_out_time: "18:00", reason: "打刻を忘れました")
      assert request.submit, request.errors.full_messages.inspect
    end

    board = dashboard
    assert_equal 1, board.actionable_approval_count, "自分の申請（他の管理者が処理する）は数えない"
    assert_equal ApprovalRequest.actionable_by(@admin).count, board.actionable_approval_count
    assert_equal 3, board.pending_approval_count
    assert_equal 3, dashboard(admin: admin2).actionable_approval_count

    admin2.update!(active: false)
    assert_equal 3, dashboard.actionable_approval_count, "有効な管理者が1人なら、自分の申請も数える"
  end

  test "退勤漏れ：前日以前に退勤が無い勤務の件数（勤務中で、まだ退勤できる勤務も数え、その件数も分かる）" do
    attendance!(@employee, at(Date.new(2026, 11, 20), 9, 0))
    attendance!(@inactive, at(Date.new(2026, 11, 18), 9, 0))
    night = member!
    attendance!(night, at(YESTERDAY, 22, 0))
    attendance!(member!, at(TODAY, 9, 0))
    attendance!(member!, at(YESTERDAY, 9, 0), at(YESTERDAY, 18, 0))

    missing = dashboard.missing_clock_outs
    assert_equal 3, missing.count
    assert_equal 1, missing.open_count
    assert_equal [ YESTERDAY, Date.new(2026, 11, 20), Date.new(2026, 11, 18) ], missing.items.map(&:work_date)
    assert_equal Attendance.all.count { |item| item.missing_clock_out?(as_of: NOW) }, missing.count, "勤怠履歴の「退勤漏れ」と同じ数え方"
  end

  test "残業の警告：今月度の残業が警告ラインの80%を超えた人（ちょうど 80% は出さない）。値は MonthlyAttendance と同じ" do
    near = member!("あと少し")
    exact = member!("ちょうど")
    over = member!("超えた")
    # 8:00〜22:00（休憩なし）＝ 実働 14:00・残業 6:00。6日で 36:00（45時間の 80%）
    (Date.new(2026, 11, 2)..Date.new(2026, 11, 7)).each do |date|
      [ near, exact, over ].each { |user| attendance!(user, at(date, 8, 0), at(date, 22, 0)) }
    end
    attendance!(near, at(Date.new(2026, 11, 9), 8, 0), at(Date.new(2026, 11, 9), 16, 1))
    (Date.new(2026, 11, 10)..Date.new(2026, 11, 11)).each { |date| attendance!(over, at(date, 8, 0), at(date, 23, 0)) }
    attendance!(over, at(Date.new(2026, 11, 12), 8, 0), at(Date.new(2026, 11, 12), 8, 1))

    board = dashboard
    assert_equal 36 * 60, board.overtime_alert_minutes
    rows = board.overtime_rows
    assert_equal [ over, near ], rows.map(&:user)
    assert_equal (36 + 14) * 60, rows.first.overtime_minutes
    assert_equal (36 * 60) + 1, rows.second.overtime_minutes
    assert rows.first.over_warning?
    assert_not rows.second.over_warning?
    assert_equal 80, rows.second.percentage

    period = WorkRules.new.period_containing(TODAY)
    assert_equal MonthlyAttendance.new(over, period: period, now: NOW).total_overtime_minutes, rows.first.overtime_minutes
  end

  test "残業の警告：月度は締め日に従う（20日締めの 11/25 は 11/21〜12/20 の月度）" do
    user = member!
    (Date.new(2026, 11, 10)..Date.new(2026, 11, 16)).each { |date| attendance!(user, at(date, 8, 0), at(date, 22, 0)) }
    assert_equal [ user ], dashboard.overtime_rows.map(&:user)

    rules = WorkRules.new(closing_day: 20)
    board = dashboard(rules: rules)
    assert_equal Date.new(2026, 11, 21), board.period.start_date
    assert_empty board.overtime_rows

    lower = dashboard(rules: WorkRules.new(overtime_warning_hours: 60))
    assert_empty lower.overtime_rows, "警告ライン 60時間の 80%（48:00）は超えていない"
  end

  test "MonthlyAttendance.for_users：まとめて読んでも、1人ずつ作ったときと同じ値" do
    shift!(@employee, YESTERDAY, "9:00", "18:00")
    attendance!(@employee, at(YESTERDAY, 9, 5), at(YESTERDAY, 20, 0))
    approved_leave!(@admin, YESTERDAY)
    period = WorkRules.new.period_containing(TODAY)

    batch = MonthlyAttendance.for_users([ @employee, @admin ], period: period, now: NOW)
    [ @employee, @admin ].each do |user|
      single = MonthlyAttendance.new(user, period: period, now: NOW)
      %i[total_worked_minutes total_overtime_minutes late_count early_leave_count absence_count working_days_count leave_day_totals].each do |key|
        assert_equal single.public_send(key), batch.fetch(user.id).public_send(key), "#{user.name} #{key}"
      end
    end
    assert_equal 1, batch.fetch(@employee.id).late_count
  end
end
