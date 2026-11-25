require "test_helper"

# シフト作成（F11）の画面：シフト表・マスごとの登録・変更・削除・パターンの割り当て・前週のコピー・公開
class Admin::ShiftsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-25 は水曜日。今週は 11/23（月・勤労感謝の日）〜11/29（日）
  NOW = Time.zone.local(2026, 11, 25, 10, 0)
  WEEK = Date.new(2026, 11, 23)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    @inactive = users(:inactive_employee)
  end

  teardown { travel_back }

  def shift!(date, start_time = "9:00", end_time = "18:00", user: @employee)
    shift = Shift.new(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: 60, updated_by: @admin)
    shift.save!(validate: user.active?)
    shift
  end

  def approved_leave!(from, to = from, part: "full_day")
    leave = @employee.leave_requests.new(target_date: from, end_date: to, leave_type: "paid", day_part: part, reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  def cell_selector(user, date)
    "td#shift_cell_#{user.id}_#{date.iso8601}"
  end

  test "シフト表：縦に有効な従業員・横に月〜日。祝日は赤で祝日名、各日の人数、前週・翌週へのリンク" do
    shift!(WEEK + 2)
    shift!(WEEK + 2, "13:00", "22:00", user: @admin)
    shift!(WEEK + 2, user: @inactive)
    sign_in_as @admin

    get admin_shifts_path
    assert_response :success
    assert_select "h1", "シフト作成"
    assert_select "[data-testid='week-range']", text: /2026年11月23日\(月\)〜11月29日\(日\)/
    assert_select "[data-testid='shift-day-head']", 7
    assert_select "[data-testid='shift-day-head'][data-date='2026-11-23'].shift-day--holiday" do
      assert_select "[data-testid='holiday-name']", "勤労感謝の日"
    end
    assert_select "[data-testid='shift-day-head'][data-date='2026-11-29'].shift-day--sunday"
    assert_select "[data-testid='shift-day-head'][data-date='2026-11-28'].shift-day--saturday"
    assert_select "[data-testid='shift-day-head'][data-date='2026-11-25'] [data-testid='shift-day-count']", "2人"
    assert_select "[data-testid='shift-row']", 2
    assert_select "tr#shift_row_#{@inactive.id}", 0
    assert_select "#{cell_selector(@employee, WEEK + 2)}[data-state='draft'] [data-testid='shift-cell-time']", "9:00〜18:00"
    assert_select "#{cell_selector(@employee, WEEK + 2)} a[href='#{edit_admin_shift_path(Shift.find_by(user: @employee))}']"
    assert_select "#{cell_selector(@employee, WEEK + 3)} a[href='#{new_admin_shift_path(user_id: @employee.id, date: '2026-11-26')}']"
    assert_select "[data-testid='inactive-shift']", text: /退職 次郎 さん・11\/25\(水\)/
    assert_select "a[data-testid='previous-week'][href='#{admin_shifts_path(week: '2026-11-16')}']"
    assert_select "a[data-testid='next-week'][href='#{admin_shifts_path(week: '2026-11-30')}']"
    assert_select "[data-testid='week-status'][data-status='draft']"

    get admin_shifts_path(week: "2026-12-02")
    assert_select "[data-testid='week-range']", text: /2026年11月30日\(月\)〜12月6日\(日\)/
    assert_select "[data-testid='week-status'][data-status='empty']"
  end

  test "解釈できない・範囲外の週は、今週に戻して知らせる" do
    sign_in_as @admin
    get admin_shifts_path(week: "abc")
    assert_redirected_to admin_shifts_path
    assert_equal Admin::ShiftWeekParam::INVALID_WEEK_MESSAGE, flash[:alert]

    get admin_shifts_path(week: "2028-01-03")
    assert_redirected_to admin_shifts_path
  end

  test "従業員ロールはシフト作成の画面・操作を使えない" do
    shift = shift!(WEEK + 2)
    sign_in_as @employee
    get admin_shifts_path
    assert_redirected_to root_path
    post admin_shifts_path, params: { shift: { user_id: @employee.id, work_date: "2026-11-26", start_time: "9:00", end_time: "18:00" } }
    assert_redirected_to root_path
    patch admin_shift_path(shift), params: { shift: { start_time: "1:00" } }
    delete admin_shift_path(shift)
    post admin_shifts_publication_path, params: { week: WEEK.iso8601 }
    post admin_shifts_copy_path, params: { week: WEEK.iso8601 }
    assert_equal "9:00〜18:00", shift.reload.range_label
    assert_equal :draft, shift.state
    assert_equal 0, ShiftPublication.count
  end

  test "マスを選んで、開始・終了・休憩を入れて登録できる（日付をまたぐシフトも）" do
    sign_in_as @admin
    get new_admin_shift_path(user_id: @employee.id, date: "2026-11-26")
    assert_response :success
    assert_select "[data-testid='shift-form-title']", text: /従業 花子 さん・11月26日\(木\)/
    assert_select "input[name='shift[break_minutes]'][value='60']"

    post admin_shifts_path, params: { shift: { user_id: @employee.id, work_date: "2026-11-26", start_time: "22:00", end_time: "06:00", break_minutes: "60" } }
    assert_redirected_to admin_shifts_path(week: "2026-11-23")
    assert_equal "11/26(木) 従業 花子 さんのシフト（22:00〜翌6:00）を登録しました（下書き）。週を「公開」するまで、従業員には見えません。", flash[:notice]
    shift = Shift.find_by!(user: @employee, work_date: Date.new(2026, 11, 26))
    assert_equal [ 1320, 360, 60, @admin ], [ shift.start_minute, shift.end_minute, shift.break_minutes, shift.created_by ]

    get admin_shifts_path
    assert_select "#{cell_selector(@employee, Date.new(2026, 11, 26))} [data-testid='shift-cell-time']", "22:00〜翌6:00"
  end

  test "不正な値（終了＝開始、休憩が勤務時間以上、数値でない休憩）は登録できず、入力画面にエラーを出す" do
    sign_in_as @admin
    post admin_shifts_path, params: { shift: { user_id: @employee.id, work_date: "2026-11-26", start_time: "9:00", end_time: "9:00", break_minutes: "abc" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors", text: /終了時刻が開始時刻と同じです/
    assert_select ".form-errors", text: /休憩時間は数値（分）で入力してください/

    post admin_shifts_path, params: { shift: { user_id: @employee.id, work_date: "2026-11-26", start_time: "9:00", end_time: "10:00", break_minutes: "60" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors", text: /休憩時間は勤務時間（1:00）より短くしてください/
    assert_equal 0, Shift.count

    post admin_shifts_path, params: { shift: { user_id: @inactive.id, work_date: "2026-11-26", start_time: "9:00", end_time: "18:00" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors", text: /無効な従業員にはシフトを登録・変更できません/

    post admin_shifts_path, params: { shift: { user_id: 9999, work_date: "2026-11-26" } }
    assert_redirected_to admin_shifts_path(week: "2026-11-23")
    post admin_shifts_path
    assert_response :see_other
  end

  test "変更すると下書きが変わり、公開済みなら公開中の内容は公開まで変わらないことを知らせる" do
    shift = shift!(WEEK + 3)
    shift.publish_draft!(now: NOW)
    sign_in_as @admin

    get edit_admin_shift_path(shift)
    assert_select "[data-testid='shift-publication-state']", text: /公開済みです/
    patch admin_shift_path(shift), params: { shift: { start_time: "10:00", end_time: "19:00", break_minutes: "45", lock_version: shift.lock_version } }
    assert_redirected_to admin_shifts_path(week: "2026-11-23")
    assert_includes flash[:notice], "11/26(木) 従業 花子 さんのシフトを 10:00〜19:00（休憩45分）に変更しました。公開中の内容（9:00〜18:00）は、週を「公開」するまで変わりません。"
    assert_equal :changed, shift.reload.state

    get admin_shifts_path
    assert_select "#{cell_selector(@employee, WEEK + 3)}[data-state='changed']" do
      assert_select "[data-testid='shift-state']", "変更・未公開"
      assert_select "[data-testid='shift-cell-published']", "公開中 9:00〜18:00"
    end
    assert_select "[data-testid='week-status'][data-status='changed']", "公開後の変更あり（未公開）"
    assert_select "[data-testid='week-status-detail']", text: /未公開の変更：変更 1件/
  end

  test "同じマスを2人の管理者が同時に編集：後から保存した側は保存されず、最新の内容を見せて知らせる（500 にならない）" do
    shift = shift!(WEEK + 3)
    old_version = shift.lock_version
    other_admin = User.create!(name: "別の 管理者", email: "other-admin@example.com", password: "password123", role: "admin", hired_on: Date.new(2020, 4, 1))
    Shift.find(shift.id).update!(start_time: "11:00", end_time: "20:00", updated_by: other_admin)

    sign_in_as @admin
    patch admin_shift_path(shift), params: { shift: { start_time: "8:00", end_time: "17:00", break_minutes: "60", lock_version: old_version } }
    assert_response :conflict
    assert_select ".flash--alert", text: /別の 管理者 さんが先にこのシフトを 11:00〜20:00（休憩60分）に変更したため、入力した内容（8:00〜17:00）は保存していません/
    assert_select "input[name='shift[start_time]'][value='11:00']"
    assert_equal "11:00〜20:00", shift.reload.range_label

    delete admin_shift_path(shift), params: { lock_version: old_version }
    assert_redirected_to edit_admin_shift_path(shift)
    assert Shift.exists?(shift.id)
  end

  test "空いたマスに他の管理者が先に登録していたら、登録せずに最新の内容を見せる" do
    shift!(WEEK + 3, "13:00", "22:00")
    sign_in_as @admin
    post admin_shifts_path, params: { shift: { user_id: @employee.id, work_date: "2026-11-26", start_time: "9:00", end_time: "18:00", break_minutes: "60" } }
    assert_response :conflict
    assert_select ".flash--alert", text: /他の管理者が先にこのマスにシフト（13:00〜22:00）を登録したため、登録しませんでした/
    assert_equal 1, Shift.count

    get new_admin_shift_path(user_id: @employee.id, date: "2026-11-26")
    assert_redirected_to edit_admin_shift_path(Shift.last)
  end

  test "削除：未公開ならすぐに消え、公開済みなら削除予定になり、公開で消える" do
    draft = shift!(WEEK + 3)
    published = shift!(WEEK + 4)
    published.publish_draft!(now: NOW)
    sign_in_as @admin

    delete admin_shift_path(draft), params: { lock_version: draft.lock_version }
    assert_redirected_to admin_shifts_path(week: "2026-11-23")
    assert_not Shift.exists?(draft.id)

    delete admin_shift_path(published), params: { lock_version: published.reload.lock_version }
    assert_includes flash[:notice], "公開中のシフトのため、週を「公開」すると従業員の画面からも消えます"
    assert_equal :removing, published.reload.state

    get admin_shifts_path
    assert_select "#{cell_selector(@employee, WEEK + 4)}[data-state='removing']" do
      assert_select "[data-testid='shift-state']", "削除・未公開"
    end
    assert_select "[data-testid='shift-day-head'][data-date='2026-11-27'] [data-testid='shift-day-count']", "0人"

    get edit_admin_shift_path(published)
    assert_redirected_to new_admin_shift_path(user_id: @employee.id, date: "2026-11-27")
    patch admin_shift_path(published), params: { shift: { start_time: "1:00" } }
    assert_redirected_to admin_shifts_path(week: "2026-11-23")

    post admin_shifts_publication_path, params: { week: WEEK.iso8601 }
    assert_not Shift.exists?(published.id)

    delete admin_shift_path(published)
    assert_response :see_other
    assert_includes flash[:alert], "指定されたシフトが見つかりません"
  end

  test "承認済みの休暇の日のマスに「休暇」と出て、シフトを入れようとすると警告し、確認すれば登録できる" do
    approved_leave!(Date.new(2026, 11, 26))
    approved_leave!(Date.new(2026, 11, 27), part: "morning")
    sign_in_as @admin

    get admin_shifts_path
    assert_select "#{cell_selector(@employee, Date.new(2026, 11, 26))}[data-leave='full'] [data-testid='shift-cell-leave']", "休暇"
    assert_select "#{cell_selector(@employee, Date.new(2026, 11, 27))}[data-leave='half'] [data-testid='shift-cell-half-leave']", "午前半休"

    get new_admin_shift_path(user_id: @employee.id, date: "2026-11-26")
    assert_select "[data-testid='shift-leave-warning']", text: /この日は 従業 花子 さんの休暇（有給（全日））の日です/
    assert_select "input[type='checkbox'][name='shift[leave_acknowledged]']"

    params = { user_id: @employee.id, work_date: "2026-11-26", start_time: "9:00", end_time: "18:00", break_minutes: "60" }
    post admin_shifts_path, params: { shift: params }
    assert_response :unprocessable_entity
    assert_select ".form-errors", text: /休暇の日と確認したうえで登録する」にチェックを入れてください/
    post admin_shifts_path, params: { shift: params.merge(leave_acknowledged: "1") }
    assert_response :redirect
    get admin_shifts_path
    assert_select "#{cell_selector(@employee, Date.new(2026, 11, 26))}.shift-cell--conflict [data-testid='shift-cell-conflict']"

    get new_admin_shift_path(user_id: @employee.id, date: "2026-11-27")
    assert_select "[data-testid='shift-half-leave-note']", text: /午前半休/
    post admin_shifts_path, params: { shift: params.merge(work_date: "2026-11-27", start_time: "13:00") }
    assert_response :redirect
  end

  test "パターンで割り当て：マスを押すとパターンが入り、同じシフト表の URL に戻る。休暇の日は警告して入れない" do
    early = ShiftPattern.create!(name: "早番", start_time: "9:00", end_time: "18:00", break_minutes: 60)
    approved_leave!(Date.new(2026, 11, 27))
    sign_in_as @admin

    get admin_shifts_path(week: WEEK.iso8601, pattern: early.id)
    assert_select "[data-testid='brush-pattern'].is-active", text: /早番/
    assert_select "#{cell_selector(@employee, Date.new(2026, 11, 26))} form[action='#{admin_shifts_assignments_path}']"

    post admin_shifts_assignments_path, params: { user_id: @employee.id, date: "2026-11-26", pattern_id: early.id, lock_version: "" }
    assert_redirected_to admin_shifts_path(week: WEEK.iso8601, pattern: early.id)
    assert_equal "11/26(木) 従業 花子 さんに「早番」（9:00〜18:00）を割り当てました（下書き）。", flash[:toast_notice]
    assert_equal "9:00〜18:00", Shift.find_by!(user: @employee, work_date: Date.new(2026, 11, 26)).range_label

    post admin_shifts_assignments_path, params: { user_id: @employee.id, date: "2026-11-27", pattern_id: early.id, lock_version: "" }
    assert_redirected_to admin_shifts_path(week: WEEK.iso8601, pattern: early.id)
    assert_includes flash[:toast_alert], "11/27(金) は 従業 花子 さんの休暇（有給（全日））の日のため、割り当てませんでした"

    post admin_shifts_assignments_path, params: { user_id: @employee.id, date: "2026-11-26", pattern_id: 9999 }
    assert_includes flash[:alert], "割り当てるシフトパターンが見つかりません"
    get admin_shifts_assignments_path
    assert_response :see_other
  end

  test "前週をコピー：確認の文言に見込みの件数を出し、すでにあるマスは上書きしない" do
    shift!(WEEK - 7)
    shift!(WEEK - 6)
    existing = shift!(WEEK, "13:00", "22:00")
    sign_in_as @admin

    get admin_shifts_path
    assert_select "form[data-testid='copy-form'][data-turbo-confirm*='コピーする見込み：1件']"
    assert_select "form[data-testid='copy-form'][data-turbo-confirm*='すでにシフトがあるマス 1件']"

    post admin_shifts_copy_path, params: { week: WEEK.iso8601 }
    assert_redirected_to admin_shifts_path(week: WEEK.iso8601)
    assert_equal "前週（11/16〜11/22）のシフトを 1件 コピーしました（下書き）。すでにシフトがあるマス 1件 はコピーしていません（上書きはしません）。" \
                 "内容を確かめてから、週を「公開」してください。", flash[:notice]
    assert_equal "13:00〜22:00", existing.reload.range_label

    post admin_shifts_copy_path, params: { week: WEEK.iso8601 }
    assert_includes flash[:alert], "コピーできるマスがありませんでした"
    get admin_shifts_copy_path(week: WEEK.iso8601)
    assert_redirected_to admin_shifts_path(week: WEEK.iso8601)
  end

  test "この週を公開：公開すると状態と履歴が変わり、公開後に変更すると分かる" do
    shift = shift!(WEEK + 2)
    sign_in_as @admin

    get admin_shifts_path
    assert_select "form[data-testid='publish-form'][data-turbo-confirm*='追加 1件']"
    post admin_shifts_publication_path, params: { week: WEEK.iso8601 }
    assert_redirected_to admin_shifts_path(week: WEEK.iso8601)
    assert_equal "11/23〜11/29 のシフトを公開しました（追加 1件）。従業員の画面に反映されます。", flash[:notice]

    get admin_shifts_path
    assert_select "[data-testid='week-status'][data-status='published']", "公開済み"
    assert_select "[data-testid='week-status-detail']", text: /最終公開 11\/25 10:00（管理 太郎）/
    assert_select "[data-testid='publish-disabled'][disabled]"
    assert_select "[data-testid='shift-publication']", 1

    post admin_shifts_publication_path, params: { week: WEEK.iso8601 }
    assert_includes flash[:alert], "この週には公開する変更がありません"

    patch admin_shift_path(shift), params: { shift: { start_time: "10:00", end_time: "18:00", break_minutes: "60", lock_version: shift.reload.lock_version } }
    get admin_shifts_path
    assert_select "[data-testid='week-status'][data-status='changed']"
    post admin_shifts_publication_path, params: { week: WEEK.iso8601 }
    assert_includes flash[:notice], "（変更 1件）"
    get admin_shifts_path
    assert_select "[data-testid='shift-publication']", 2
    assert_select "[data-testid='shift-publication']", text: /変更 1件.*公開後の変更を反映/m
  end

  test "管理メニューに「シフト作成」がある" do
    sign_in_as @admin
    get root_path
    assert_select "[data-testid='admin-menu'] a[data-testid='nav-shifts'][href='#{admin_shifts_path}']", "シフト作成"
    get admin_shifts_path
    assert_select "a[data-testid='nav-shifts'][aria-current='page']"
  end
end
