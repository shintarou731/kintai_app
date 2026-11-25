require "test_helper"

# シフト確認と予実比較（F12）の画面：従業員の「シフト」（月のカレンダー）・ホームの今日と次回のシフト・勤怠履歴の予定と実績・
# 管理者の「予実の確認」（従業員ごと・月度ごとの遅刻・早退・欠勤の回数）
class ShiftChecksScreensTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-25（水）10:00
  NOW = Time.zone.local(2026, 11, 25, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    @inactive = users(:inactive_employee)
  end

  teardown { travel_back }

  def shift!(date, start_time = "9:00", end_time = "18:00", user: @employee, publish: true, break_minutes: 60)
    shift = Shift.new(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: break_minutes)
    shift.save!(validate: user.active?)
    shift.publish_draft!(now: NOW - 2.days) if publish
    shift
  end

  def attendance!(date, clock_in, clock_out = nil, user: @employee)
    to_time = ->(value) { value && Time.zone.parse("#{date.iso8601} #{value}") }
    Attendance.create!(user: user, work_date: date, clock_in_at: to_time.call(clock_in), clock_out_at: to_time.call(clock_out))
  end

  def approved_leave!(date, part: "full_day", user: @employee)
    leave = user.leave_requests.new(target_date: date, end_date: date, leave_type: "paid", day_part: part, reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  def day_cell(date)
    "[data-testid='calendar-day'][data-date='#{date.iso8601}']"
  end

  test "ナビに「シフト」があり、自分の公開済みシフトだけを月のカレンダーで見られる（下書き・未公開の変更は出さない）" do
    shift!(Date.new(2026, 11, 26), "13:00", "22:00")
    shift!(Date.new(2026, 11, 27), publish: false)
    changed = shift!(Date.new(2026, 11, 30))
    changed.update!(start_time: "10:00", end_time: "19:00")
    shift!(Date.new(2026, 11, 26), "9:00", "17:00", user: @admin)
    sign_in_as @employee

    get root_path
    assert_select "nav a[href='#{shifts_path}'][data-testid='nav-my-shifts']", "シフト"
    get shifts_path
    assert_response :success
    assert_select "[data-testid='calendar-month']", /2026年11月/
    assert_select "[data-testid='calendar-day']", 30
    assert_select "#{day_cell(Date.new(2026, 11, 26))} [data-testid='calendar-shift']", "13:00〜22:00"
    assert_select "#{day_cell(Date.new(2026, 11, 27))} [data-testid='calendar-shift']", count: 0
    assert_select "#{day_cell(Date.new(2026, 11, 30))} [data-testid='calendar-shift']", "9:00〜18:00"
    assert_select "[data-testid='calendar-shift']", text: "10:00〜19:00", count: 0
    assert_select "[data-testid='shift-days']", /2日/
    assert_select "[data-testid='shift-scheduled-total']", "16:00"
  end

  test "カレンダー：祝日は日曜と同じ赤で祝日名、日付をまたぐシフトは「翌」、公開後に変わったシフトは「変更あり」" do
    night = shift!(Date.new(2026, 11, 28), "22:00", "6:00")
    revised = shift!(Date.new(2026, 11, 24))
    revised.update!(start_time: "10:00")
    revised.publish_draft!(now: NOW - 1.day)
    sign_in_as @employee

    get shifts_path(month: "2026-11")
    assert_select "#{day_cell(Date.new(2026, 11, 23))}.shift-calendar__day--holiday [data-testid='holiday-name']", "勤労感謝の日"
    assert_select "#{day_cell(Date.new(2026, 11, 29))}.shift-calendar__day--sunday"
    assert_select "#{day_cell(Date.new(2026, 11, 28))}.shift-calendar__day--saturday [data-testid='calendar-shift']", "22:00〜翌6:00"
    assert_select "#{day_cell(Date.new(2026, 11, 29))} [data-testid='calendar-shift']", count: 0
    assert_select "#{day_cell(Date.new(2026, 11, 24))} [data-testid='shift-revised']", "変更あり"
    assert_select "#{day_cell(night.work_date)} [data-testid='shift-revised']", count: 0
    assert_select "[data-testid='shift-revised-note']", /11\/24\(火\)/

    get shifts_path(month: "2027-01")
    assert_select "#{day_cell(Date.new(2027, 1, 1))} [data-testid='holiday-name']", "元日"
    get shifts_path(month: "abc")
    assert_redirected_to shifts_path
  end

  test "カレンダー：過去の日に遅刻・欠勤の印、休暇の日に休暇を出す" do
    shift!(Date.new(2026, 11, 17))
    attendance!(Date.new(2026, 11, 17), "9:10", "18:00")
    shift!(Date.new(2026, 11, 18))
    shift!(Date.new(2026, 11, 19))
    approved_leave!(Date.new(2026, 11, 19))
    sign_in_as @employee

    get shifts_path
    assert_select "#{day_cell(Date.new(2026, 11, 17))} [data-testid='shift-mark'][data-mark='late']", "遅刻 0:10"
    assert_select "#{day_cell(Date.new(2026, 11, 18))} [data-testid='shift-mark'][data-mark='absent']", "欠勤"
    assert_select "#{day_cell(Date.new(2026, 11, 19))} [data-testid='calendar-leave']", /有給（全日）/
    assert_select "#{day_cell(Date.new(2026, 11, 19))} [data-testid='shift-mark']", count: 0
  end

  test "ホーム：今日と次回のシフト（公開済みだけ）" do
    shift!(Date.new(2026, 11, 25), "11:00", "20:00")
    shift!(Date.new(2026, 11, 26), publish: false)
    shift!(Date.new(2026, 11, 27), "13:00", "22:00")
    sign_in_as @employee

    get root_path
    assert_select "[data-testid='home-today-shift']", /11:00〜20:00/
    assert_select "[data-testid='home-next-shift']", /11\/27\(金\)\s*13:00〜22:00/
    assert_select "[data-testid='home-today-shift'] [data-testid='shift-pending']", count: 0
  end

  test "ホーム：シフトが無ければ「シフトなし」「予定なし」。開始を過ぎても出勤していなければ「未出勤」、遅れて出勤すれば「遅刻」" do
    sign_in_as @employee
    get root_path
    assert_select "[data-testid='home-today-shift']", /シフトなし/
    assert_select "[data-testid='home-next-shift']", /予定なし/

    shift!(Date.new(2026, 11, 25), "9:00", "18:00")
    get root_path
    assert_select "[data-testid='home-today-shift'] [data-testid='shift-pending']", "未出勤"
    attendance!(Date.new(2026, 11, 25), "9:30")
    get root_path
    assert_select "[data-testid='home-today-shift'] [data-testid='shift-mark'][data-mark='late']", "遅刻 0:30"
  end

  test "ホーム：前日からの日付をまたぐシフトの途中なら、その旨を出す" do
    travel_to Time.zone.local(2026, 11, 26, 2, 0)
    shift!(Date.new(2026, 11, 25), "22:00", "6:00")
    sign_in_as @employee
    get root_path
    assert_select "[data-testid='home-ongoing-shift']", /11\/25\(水\).*22:00〜翌6:00/
  end

  test "勤怠履歴：各日に予定（シフト）と実績（打刻）を並べ、遅刻・早退・欠勤の印と回数を出す" do
    shift!(Date.new(2026, 11, 16))                      # 欠勤
    shift!(Date.new(2026, 11, 17))
    attendance!(Date.new(2026, 11, 17), "9:01", "17:30") # 早退（遅刻ではない）
    shift!(Date.new(2026, 11, 18))
    attendance!(Date.new(2026, 11, 18), "9:02", "18:00") # 遅刻
    shift!(Date.new(2026, 11, 19), "22:00", "6:00")
    Attendance.create!(user: @employee, work_date: Date.new(2026, 11, 19), clock_in_at: Time.zone.local(2026, 11, 19, 22, 0),
                       clock_out_at: Time.zone.local(2026, 11, 20, 6, 0)) # 予定どおり（日付をまたぐ）
    shift!(Date.new(2026, 11, 20))
    approved_leave!(Date.new(2026, 11, 20))              # 休暇の日（欠勤にしない）
    shift!(Date.new(2026, 11, 26))                      # 未来の日（欠勤にしない）
    sign_in_as @employee

    get attendances_path
    row = ->(date) { "tr[data-date='#{date.iso8601}']" }
    assert_select "#{row.call(Date.new(2026, 11, 16))} [data-testid='day-shift']", "9:00〜18:00"
    assert_select "#{row.call(Date.new(2026, 11, 16))} [data-testid='shift-mark'][data-mark='absent']", "欠勤"
    assert_select "#{row.call(Date.new(2026, 11, 17))} [data-column='clock-in']", "09:01"
    assert_select "#{row.call(Date.new(2026, 11, 17))} [data-testid='shift-mark']", 1
    assert_select "#{row.call(Date.new(2026, 11, 17))} [data-testid='shift-mark'][data-mark='early_leave']", "早退 0:30"
    assert_select "#{row.call(Date.new(2026, 11, 18))} [data-testid='shift-mark'][data-mark='late']", "遅刻 0:02"
    assert_select "#{row.call(Date.new(2026, 11, 19))} [data-testid='day-shift']", "22:00〜翌6:00"
    assert_select "#{row.call(Date.new(2026, 11, 19))} [data-testid='shift-mark']", 0
    assert_select "#{row.call(Date.new(2026, 11, 20))} [data-testid='shift-mark']", 0
    assert_select "#{row.call(Date.new(2026, 11, 26))} [data-testid='day-shift']", "9:00〜18:00"
    assert_select "#{row.call(Date.new(2026, 11, 26))} [data-testid='shift-mark']", 0
    assert_select "#{row.call(Date.new(2026, 11, 26))} .history-table__empty-label", 0
    assert_select "tr.history-row--has-shift", 6

    assert_select "[data-testid='total-scheduled']", "6日"
    assert_select "[data-testid='total-late']", "1回"
    assert_select "[data-testid='total-early-leave']", "1回"
    assert_select "[data-testid='total-absence']", "1回"
  end

  test "管理者の予実の確認：従業員ごとの回数を、締め日（F6）の月度で数える" do
    WorkRuleSetting.create!(scheduled_work_time: "8:00", standard_break_time: "1:00", closing_day: "20", overtime_warning_hours: "45")
    # 20日締め：11月度は 10/21〜11/20、12月度は 11/21〜12/20
    shift!(Date.new(2026, 11, 19))                      # 11月度の欠勤
    shift!(Date.new(2026, 11, 20))
    attendance!(Date.new(2026, 11, 20), "9:05", "18:00") # 11月度の遅刻
    shift!(Date.new(2026, 11, 24))
    attendance!(Date.new(2026, 11, 24), "9:00", "17:00") # 12月度の早退
    shift!(Date.new(2026, 11, 24), user: @admin)         # 12月度の欠勤（管理者本人）
    sign_in_as @admin

    get root_path
    assert_select "a[href='#{admin_shift_reports_path}'][data-testid='nav-shift-reports']", "予実の確認"
    get admin_shift_reports_path
    assert_response :success
    assert_select "[data-testid='period-label']", /2026年12月度/
    assert_select "[data-testid='period-range']", "11/21(土)〜12/20(日)"
    employee_row = "[data-testid='shift-report-row'][data-user-id='#{@employee.id}']"
    assert_select "#{employee_row} [data-column='late']", "0回"
    assert_select "#{employee_row} [data-column='early_leave']", "1回"
    assert_select "#{employee_row} [data-column='absent']", "0回"
    assert_select "[data-testid='shift-report-row'][data-user-id='#{@admin.id}'] [data-column='absent']", "1回"
    assert_select "[data-testid='shift-report-row'][data-user-id='#{@inactive.id}']", 0
    assert_select "[data-testid='total-absence']", /1/

    get admin_shift_reports_path(month: "2026-11")
    assert_select "[data-testid='period-range']", "10/21(水)〜11/20(金)"
    assert_select "#{employee_row} [data-column='late']", "1回"
    assert_select "#{employee_row} [data-column='absent']", "1回"
    assert_select "#{employee_row} [data-column='early_leave']", "0回"

    get admin_shift_report_path(@employee, month: "2026-11")
    assert_response :success
    assert_select "[data-testid='report-day'][data-date='2026-11-19'] [data-testid='shift-mark'][data-mark='absent']"
    assert_select "[data-testid='report-day'][data-date='2026-11-20'] [data-testid='shift-mark'][data-mark='late']", "遅刻 0:05"
    assert_select "[data-testid='user-late']", /1/
  end

  test "予実の確認：無効な従業員も、その月度にシフトか勤怠があれば出す。不正な月・従業員は戻す" do
    shift!(Date.new(2026, 11, 24), user: @inactive)
    sign_in_as @admin
    get admin_shift_reports_path
    assert_select "[data-testid='shift-report-row'][data-user-id='#{@inactive.id}'] [data-column='absent']", "1回"

    get admin_shift_reports_path(month: "2026-13")
    assert_redirected_to admin_shift_reports_path
    get admin_shift_report_path(99_999)
    assert_redirected_to admin_shift_reports_path(month: "2026-11")
  end

  test "従業員は予実の確認を開けない" do
    sign_in_as @employee
    get admin_shift_reports_path
    assert_redirected_to root_path
    get admin_shift_report_path(@employee)
    assert_redirected_to root_path
  end
end
