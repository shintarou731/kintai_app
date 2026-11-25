require "test_helper"

# 管理者のダッシュボード（F13）と、前日以前の退勤漏れの一覧の画面。あわせてスプリント12の評価の指摘（画面の文言・折り返し）も確かめる
class Admin::DashboardsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-25（水）10:00
  NOW = Time.zone.local(2026, 11, 25, 10, 0)
  TODAY = NOW.to_date

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

  def at(date, hour, minute = 0)
    Time.zone.local(date.year, date.month, date.day, hour, minute)
  end

  def shift!(user, date = TODAY, start_time = "9:00", end_time = "18:00")
    shift = Shift.new(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: 60)
    shift.save!(validate: user.active?)
    shift.publish_draft!(now: NOW - 2.days)
    shift
  end

  def attendance!(user, clock_in_at, clock_out_at = nil, date: clock_in_at.to_date)
    Attendance.create!(user: user, work_date: date, clock_in_at: clock_in_at, clock_out_at: clock_out_at)
  end

  def row(user)
    "[data-testid='dashboard-row'][data-user-id='#{user.id}']"
  end

  def count_queries(&block)
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE|ROLLBACK)/i)
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end

  # 1人分の記録（勤務中・シフト・休暇・修正申請・前日の退勤漏れ・残業）を作る
  def busy_member!
    user = member!
    shift!(user)
    shift!(user, TODAY - 1)
    attendance!(user, at(TODAY - 1, 8, 0))
    attendance!(user, at(TODAY - 3, 8, 0), at(TODAY - 3, 22, 0))
    leave = user.leave_requests.new(target_date: TODAY + 1, end_date: TODAY + 1, leave_type: "paid", day_part: "full_day", reason: "私用")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    user
  end

  test "管理メニューに「ダッシュボード」があり、従業員は開けない。ログイン直後の画面はホーム（打刻）のまま" do
    sign_in_as @admin
    follow_redirect!
    assert_equal root_path, path
    assert_select "[data-testid='clock-in-button']"
    assert_select "[data-testid='admin-menu'] a[href='#{admin_dashboard_path}'][data-testid='nav-dashboard']", "ダッシュボード"
    # ホームの「アカウント」欄（各画面へのリンクの一覧）は無く、ダッシュボードへはヘッダーの管理メニューから移る
    assert_select "[data-testid='home-dashboard-link']", count: 0

    get admin_dashboard_path
    assert_response :success
    assert_select "[data-testid='nav-dashboard'][aria-current='page']"
    assert_select "meta[name='turbo-cache-control'][content='no-cache']"
    assert_select "[data-testid='dashboard-as-of']", /11月25日.*10:00 時点/

    delete logout_path
    sign_in_as @employee
    get admin_dashboard_path
    assert_redirected_to root_path
    get admin_missing_clock_outs_path
    assert_redirected_to root_path
    follow_redirect!
    assert_select "[data-testid='nav-dashboard']", count: 0
  end

  test "一覧：有効なメンバー全員の状態・出勤時刻・シフトと、状態ごとの人数。遅れは赤く、先頭に出す" do
    working = member!("勤務 一郎")
    shift!(working)
    attendance!(working, at(TODAY, 9, 12))
    late = member!("遅れ 二郎")
    shift!(late, TODAY, "9:00", "18:00")
    night = member!("夜勤 三郎")
    shift!(night, TODAY - 1, "22:00", "6:00")
    attendance!(night, at(TODAY - 1, 22, 0), at(TODAY, 6, 5))
    leave = @employee.leave_requests.new(target_date: TODAY, end_date: TODAY, leave_type: "paid", day_part: "full_day", reason: "私用")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    attendance!(@inactive, at(TODAY, 9, 0))

    sign_in_as @admin
    get admin_dashboard_path
    assert_response :success

    assert_select "[data-testid='dashboard-count'][data-state='working']", /勤務中\s*1名/
    assert_select "[data-testid='dashboard-count'][data-state='on_break']", /休憩中\s*0名/
    assert_select "[data-testid='dashboard-count'][data-state='finished']", /退勤済み\s*1名/
    assert_select "[data-testid='dashboard-count'][data-state='not_started']", /未出勤\s*2名/
    assert_select "[data-testid='dashboard-count'][data-state='on_leave']", /休暇\s*1名/
    assert_select "[data-testid='dashboard-late-count'].dashboard-counts__sub--alert", /うち遅れ 1名/

    assert_select "[data-testid='dashboard-row']", 5
    assert_select "[data-testid='dashboard-row']:first-child[data-user-id='#{late.id}']"
    assert_select "#{row(late)}.dashboard-table__row--late [data-testid='dashboard-state'].status--danger", "未出勤（遅れ）"
    assert_select "#{row(late)} [data-testid='dashboard-late-note']", "9:00 開始から 1:00 経過"
    assert_select "#{row(late)} [data-column='shift']", /9:00〜18:00/

    assert_select "#{row(working)} [data-testid='dashboard-state']", "勤務中"
    assert_select "#{row(working)} [data-column='clock-in']", /09:12/
    assert_select "#{row(working)} [data-column='clock-in'] [data-testid='shift-mark']", "遅刻 0:12"

    assert_select "#{row(night)} [data-testid='dashboard-state']", "退勤済み"
    assert_select "#{row(night)} [data-column='clock-in']", /前日\s*22:00/
    assert_select "#{row(night)} [data-column='clock-out']", "06:05"
    assert_select "#{row(night)} [data-testid='dashboard-overnight']", /11\/24\(火\) の勤務（日付をまたいで退勤）/

    assert_select "#{row(@employee)} [data-testid='dashboard-state']", "休暇"
    assert_select "#{row(@employee)} [data-testid='dashboard-leave']", "有給（全日）"
    assert_select "#{row(@admin)} [data-testid='dashboard-state']", "未出勤"
    assert_select "#{row(@admin)} [data-column='shift']", /シフトなし/
    assert_select row(@inactive), count: 0
  end

  test "前日から日付をまたいで勤務中の人は「勤務中」で、前日からのシフトを出す" do
    travel_to at(TODAY, 1, 0)
    night = member!("夜勤 四郎")
    shift!(night, TODAY - 1, "22:00", "6:00")
    attendance!(night, at(TODAY - 1, 21, 58))

    sign_in_as @admin
    get admin_dashboard_path
    assert_select "#{row(night)} [data-testid='dashboard-state']", "勤務中"
    assert_select "#{row(night)} [data-testid='dashboard-previous-shift']", /前日からのシフト 22:00〜翌6:00/
    assert_select "#{row(night)} [data-testid='dashboard-overnight']", /日付をまたいで勤務中/
    assert_select "[data-testid='dashboard-missing']", /1件/
    assert_select "[data-testid='dashboard-missing']", /うち 1件 は日付をまたいで勤務中/
  end

  test "要対応：承認待ち（ナビのバッジと同じ件数）と退勤漏れの件数、それぞれの一覧へのリンク" do
    User.create!(name: "管理 二郎", email: "admin2@example.com", password: "password123", role: "admin", hired_on: Date.new(2021, 4, 1))
    [ [ @employee, 20 ], [ @admin, 19 ] ].each do |user, day|
      request = user.attendance_correction_requests.new(target_date: Date.new(2026, 11, day), clock_in_time: "09:00", clock_out_time: "18:00",
                                                        reason: "打刻を忘れました")
      assert request.submit, request.errors.full_messages.inspect
    end
    attendance!(@employee, at(Date.new(2026, 11, 20), 9, 0))
    attendance!(@inactive, at(Date.new(2026, 11, 18), 9, 0))

    sign_in_as @admin
    get admin_dashboard_path
    assert_select "[data-testid='approval-badge']", /1/
    assert_select "[data-testid='dashboard-approvals'] .dashboard-todo__value", /1件/
    assert_select "[data-testid='dashboard-approvals']", /ほかに、あなたの申請 1件 は他の管理者が処理します/
    assert_select "[data-testid='dashboard-approvals-link'][href='#{admin_approval_requests_path}']"
    assert_select "[data-testid='dashboard-missing'] .dashboard-todo__value", /2件/
    assert_select "[data-testid='dashboard-missing']", /修正申請が出ているもの 1件/
    assert_select "[data-testid='dashboard-missing-link'][href='#{admin_missing_clock_outs_path}']"

    get admin_missing_clock_outs_path
    assert_response :success
    assert_select "[data-testid='nav-dashboard'][aria-current='page']"
    assert_select "[data-testid='missing-total']", "2件"
    assert_select "[data-testid='missing-clock-out-row']", 2
    assert_select "[data-testid='missing-clock-out-row']:first-child[data-date='2026-11-20'][data-user-id='#{@employee.id}']"
    pending = @employee.attendance_correction_requests.pending.first
    assert_select "[data-testid='missing-clock-out-row'][data-user-id='#{@employee.id}'] [data-testid='missing-pending-link'][href='#{admin_approval_request_path(pending)}']"
    assert_select "[data-testid='missing-clock-out-row'][data-user-id='#{@inactive.id}']", /無効/
    assert_select "[data-testid='missing-closed']", 2
  end

  test "退勤漏れが無いときは0件と表示する" do
    sign_in_as @admin
    get admin_dashboard_path
    assert_select "[data-testid='dashboard-missing'] .dashboard-todo__value", /0件/
    get admin_missing_clock_outs_path
    assert_select "[data-testid='missing-clock-outs-empty']"
  end

  test "残業の警告：今月度の残業が警告ラインの80%を超えた人を一覧で出す" do
    heavy = member!("残業 多子")
    (Date.new(2026, 11, 2)..Date.new(2026, 11, 8)).each { |date| attendance!(heavy, at(date, 8, 0), at(date, 22, 0)) }

    sign_in_as @admin
    get admin_dashboard_path
    assert_select "[data-testid='dashboard-overtime-summary']", /1名/
    assert_select "[data-testid='dashboard-overtime-summary']", /警告ライン（45時間）の80%（36:00）/
    assert_select "[data-testid='dashboard-overtime-row']", 1
    assert_select "[data-testid='dashboard-overtime-row'][data-user-id='#{heavy.id}'] [data-column='overtime']", "42:00"
    assert_select "[data-testid='dashboard-overtime-row'] [data-column='percentage']", "93%"
    assert_select "[data-testid='dashboard-overtime-row'] [data-column='remaining']", /残り 3:00/
    assert_select "[data-testid='overtime-level'][data-level='near']", "80%超え"
    assert_select "[data-testid='dashboard-overtime']", /2026年11月/

    WorkRuleSetting.current.update!(overtime_warning_hours: 40)
    get admin_dashboard_path
    assert_select "[data-testid='overtime-level'][data-level='over']", "警告ライン超え"
    assert_select "[data-testid='dashboard-overtime-row'] [data-column='remaining']", /2:00 超過/

    WorkRuleSetting.current.update!(overtime_warning_hours: 60)
    get admin_dashboard_path
    assert_select "[data-testid='dashboard-overtime-empty']", /48:00/
  end

  test "再読み込みすると最新の状態になる（出勤すると、次に開いたときに勤務中に変わる）" do
    sign_in_as @admin
    get admin_dashboard_path
    assert_select "#{row(@employee)} [data-testid='dashboard-state']", "未出勤"

    attendance!(@employee, at(TODAY, 9, 59))
    get admin_dashboard_path
    assert_select "#{row(@employee)} [data-testid='dashboard-state']", "勤務中"
    assert_select "[data-testid='dashboard-reload'][href='#{admin_dashboard_path}']"
  end

  test "問い合わせの回数は、メンバーの人数によらず一定" do
    2.times { busy_member! }
    sign_in_as @admin
    get admin_dashboard_path
    few = count_queries { get admin_dashboard_path }

    6.times { busy_member! }
    many = count_queries { get admin_dashboard_path }
    assert_response :success
    assert_select "[data-testid='dashboard-row']", 10
    assert_equal few, many, "メンバーが増えても問い合わせの回数は変わらない（#{few} → #{many}）"

    missing_few = count_queries { get admin_missing_clock_outs_path }
    2.times { busy_member! }
    assert_equal missing_few, count_queries { get admin_missing_clock_outs_path }
  end

  # ---- スプリント12の評価の指摘 ----

  test "シフト画面の「次回のシフト」の時間帯は、途中で折り返さない（nowrap）" do
    shift!(@employee, TODAY + 1, "22:00", "6:00")
    sign_in_as @employee
    get shifts_path
    assert_select "[data-testid='shift-next'] .nowrap[data-testid='shift-next-range']", "22:00〜翌6:00"
  end

  test "シフトの開始前に退勤した日は、ホーム・勤怠履歴に「早退」を出さない" do
    shift!(@employee, TODAY, "17:00", "22:00")
    attendance!(@employee, at(TODAY, 0, 24), at(TODAY, 0, 24))
    sign_in_as @employee
    get root_path
    assert_select "[data-testid='home-today-shift'] [data-testid='shift-mark']", count: 0
    get attendances_path
    assert_select "[data-testid='shift-mark']", count: 0
  end

  test "無効な従業員の公開中のシフトの画面に、「変更すると『変更・未公開』」の説明を出さない" do
    shift = Shift.create!(user: @employee, work_date: TODAY + 2, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    shift.publish_draft!(now: NOW - 1.day)
    @employee.update_columns(active: false)

    sign_in_as @admin
    get edit_admin_shift_path(shift)
    assert_response :success
    assert_select "[data-testid='shift-publication-state']", text: /変更すると/, count: 0
    assert_select "[data-testid='shift-publication-state']", /削除すると「削除・未公開」/

    @employee.update_columns(active: true)
    get edit_admin_shift_path(shift)
    assert_select "[data-testid='shift-publication-state']", /変更すると「変更・未公開」/
  end
end
