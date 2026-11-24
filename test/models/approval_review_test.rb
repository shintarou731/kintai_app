require "test_helper"
require "minitest/mock"

class ApprovalReviewTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @admin = users(:admin)
    @employee = users(:employee)
  end

  def t(day, hour, min = 0)
    Time.zone.local(2026, 11, day, hour, min)
  end

  def correction(user: @employee, date: Date.new(2026, 11, 20), clock_in: "09:00", clock_out: "18:00", clock_out_day: "0",
                 breaks: [], at: NOW)
    request = user.attendance_correction_requests.new(
      target_date: date, clock_in_time: clock_in, clock_out_time: clock_out, clock_out_day: clock_out_day,
      reason: "打刻を忘れました",
      break_inputs: breaks.each_with_index.to_h do |(start, finish, start_day, end_day), index|
        [ index.to_s, { start_time: start, start_day: start_day || "0", end_time: finish, end_day: end_day || "0" } ]
      end
    )
    travel_to(at) { assert request.submit, request.errors.full_messages.inspect }
    request
  end

  def work(user: @employee, clock_in:, clock_out:, breaks: [])
    record = user.attendances.create!(work_date: clock_in.to_date, clock_in_at: clock_in, clock_out_at: clock_out)
    breaks.each { |from, to| record.breaks.create!(started_at: from, ended_at: to) }
    record
  end

  def review(request, reviewer: @admin, decision: "approve", comment: nil, at: NOW + 1.hour)
    review = ApprovalReview.new(approval_request: request, reviewer: reviewer, decision: decision, comment: comment)
    result = travel_to(at) { review.save }
    [ result, review ]
  end

  def second_admin(active: true, role: "admin")
    User.create!(name: "管理 二郎", email: "admin2@example.com", password: "password123", role: role, active: active,
                 hired_on: Date.new(2021, 4, 1))
  end

  def breaks_of(attendance)
    attendance.reload.breaks.map { |item| [ item.started_at, item.ended_at ] }
  end

  # ---- 承認で勤怠記録が申請内容どおりになる ----

  test "勤怠が無い日の申請を承認すると、申請内容どおりの勤怠（休憩を含む）が新しく作られる" do
    request = correction(breaks: [ [ "12:00", "13:00" ], [ "15:00", "15:15" ] ])
    saved, review = review(request, comment: "確認しました")

    assert saved, review.errors.full_messages.inspect
    request.reload
    assert request.approved?
    assert_equal @admin, request.reviewer
    assert_equal NOW + 1.hour, request.reviewed_at
    assert_equal "確認しました", request.review_comment
    assert_nil request.reviewed_record, "承認前は記録が無かった"

    attendance = @employee.attendances.find_by!(work_date: Date.new(2026, 11, 20))
    assert_equal t(20, 9), attendance.clock_in_at
    assert_equal t(20, 18), attendance.clock_out_at
    assert_equal [ [ t(20, 12), t(20, 13) ], [ t(20, 15), t(20, 15, 15) ] ], breaks_of(attendance)
    assert_equal 7 * 60 + 45, attendance.worked_minutes
  end

  test "既存の勤怠を承認で置き換える：出勤・退勤の変更、休憩の追加・削除・変更" do
    record = work(clock_in: t(20, 9, 2) + 11.seconds, clock_out: nil,
                  breaks: [ [ t(20, 12), t(20, 12, 30) ], [ t(20, 16), t(20, 16, 10) ] ])
    # 休憩1は 12:00〜13:00 に変更、休憩2（16:00〜16:10）は削除、15:00〜15:15 を追加。退勤は翌日 01:00
    request = correction(clock_in: "08:55", clock_out: "01:00", clock_out_day: "1",
                         breaks: [ [ "12:00", "13:00" ], [ "15:00", "15:15" ] ])
    saved, review = review(request)

    assert saved, review.errors.full_messages.inspect
    record.reload
    assert_equal t(20, 8, 55), record.clock_in_at
    assert_equal t(21, 1), record.clock_out_at
    assert_equal [ [ t(20, 12), t(20, 13) ], [ t(20, 15), t(20, 15, 15) ] ], breaks_of(record)
    assert_equal 1, Attendance.where(user: @employee).count

    # 承認前の記録が残る（承認後も比較表で変更前と比べられる）
    snapshot = request.reload.reviewed_record
    assert_equal (t(20, 9, 2) + 11.seconds).iso8601, snapshot["clock_in_at"]
    assert_nil snapshot["clock_out_at"]
    assert_equal 2, snapshot["breaks"].size
    before = request.comparison_attendance
    assert_equal t(20, 9, 2) + 11.seconds, before.clock_in_at
    assert_equal 2, before.breaks.size
  end

  test "休憩を全部消す申請を承認すると、休憩の記録が消える" do
    record = work(clock_in: t(20, 9), clock_out: t(20, 18), breaks: [ [ t(20, 12), t(20, 13) ] ])
    request = correction(clock_in: "09:00", clock_out: "18:00", breaks: [])
    saved, = review(request)

    assert saved
    assert_empty breaks_of(record)
    assert_equal 9 * 60, record.reload.worked_minutes
  end

  test "承認の結果は従業員の勤怠履歴（月次）に反映される" do
    request = correction(date: Date.new(2026, 11, 18), clock_in: "10:00", clock_out: "19:00", breaks: [ [ "12:00", "13:00" ] ])
    assert review(request).first

    travel_to(NOW + 2.hours) do
      monthly = MonthlyAttendance.new(@employee, period: WorkRules.current.period_containing(Date.new(2026, 11, 18)))
      day = monthly.days.find { |item| item.date == Date.new(2026, 11, 18) }
      assert day.worked?
      assert_equal 8 * 60, day.attendance.worked_minutes
      assert_nil monthly.pending_correction_for(Date.new(2026, 11, 18))
    end
  end

  # ---- 却下 ----

  test "却下はコメントが必須。却下しても勤怠記録は変わらない" do
    record = work(clock_in: t(20, 9), clock_out: nil)
    request = correction

    saved, review = review(request, decision: "reject", comment: "  ")
    assert_not saved
    assert_includes review.errors.full_messages, "コメントを入力してください（却下するときは、理由をコメントに書いてください）"
    assert request.reload.pending?

    saved, review = review(request, decision: "reject", comment: "タイムカードと一致しません")
    assert saved, review.errors.full_messages.inspect
    request.reload
    assert request.rejected?
    assert_equal "タイムカードと一致しません", request.review_comment
    assert_equal @admin, request.reviewer
    assert_nil record.reload.clock_out_at
    assert_equal t(20, 9), record.clock_in_at
    assert_equal t(20, 9).iso8601, request.reviewed_record["clock_in_at"]
  end

  test "コメントは500文字まで。不正な操作は受け付けない" do
    request = correction
    saved, review = review(request, comment: "あ" * 501)
    assert_not saved
    assert_includes review.errors.full_messages, "コメントは500文字以内で入力してください"

    saved, review = review(request, decision: "delete")
    assert_not saved
    assert_includes review.errors.full_messages, "操作は「承認する」か「却下する」を選んでください"
    assert request.reload.pending?
    assert_equal 0, Attendance.count
  end

  # ---- 二重承認・取り下げとの競合 ----

  test "二重承認：2回目は処理済みとして拒否され、勤怠は1回分だけ" do
    request = correction
    stale = ApprovalRequest.find(request.id) # 画面を開いた時点の（承認待ちの）申請
    assert review(request).first

    saved, review = review(stale, decision: "approve")
    assert_not saved
    assert_match "すでに#{@admin.name} さんが", review.errors.full_messages.first
    assert_match "処理済みです（承認済み）", review.errors.full_messages.first
    assert review.approval_request.approved?, "最新の状態を読み直す"
    assert_equal 1, Attendance.count

    saved, = review(stale, decision: "reject", comment: "やはり却下")
    assert_not saved
    assert request.reload.approved?
  end

  test "取り下げた申請は承認・却下できず、承認・却下した申請は取り下げできない" do
    withdrawn = correction(date: Date.new(2026, 11, 19))
    stale = ApprovalRequest.find(withdrawn.id)
    assert withdrawn.withdraw
    saved, review = review(stale)
    assert_not saved
    assert_includes review.errors.full_messages, "この申請は申請者が取り下げたため、承認・却下できません。"
    assert_equal 0, Attendance.count

    approved = correction(date: Date.new(2026, 11, 20))
    stale = ApprovalRequest.find(approved.id)
    assert review(approved).first
    assert_not stale.withdraw
    assert stale.approved?

    rejected = correction(date: Date.new(2026, 11, 18))
    assert review(rejected, decision: "reject", comment: "違います").first
    assert_not ApprovalRequest.find(rejected.id).withdraw
    assert rejected.reload.rejected?
  end

  test "勤怠の更新に失敗したら、承認も取り消される（同じトランザクション）" do
    request = correction(breaks: [ [ "12:00", "13:00" ] ])
    AttendanceBreak.stub(:create!, ->(**) { raise ActiveRecord::RecordInvalid, AttendanceBreak.new }) do
      saved, review = review(request)
      assert_not saved
      assert_match "勤怠記録を更新できなかったため、承認できませんでした", review.errors.full_messages.first
    end
    request.reload
    assert request.pending?
    assert_nil request.reviewer_id
    assert_nil request.reviewed_at
    assert_equal 0, Attendance.count, "先に作った勤怠も取り消される"
  end

  test "データベースのロック競合では false とメッセージを返す（例外にしない）" do
    request = correction
    ApprovalRequest.stub(:lock, -> { raise busy_error }) do
      saved, review = review(request)
      assert_not saved
      assert_equal [ DatabaseLockError::MESSAGE ], review.errors.full_messages
    end
    assert request.reload.pending?
  end

  # ---- 自己承認ルール ----

  test "有効な管理者が1人だけなら、自分の申請を承認でき、処理した管理者として本人が記録される" do
    own = correction(user: @admin)
    assert_equal :allowed, own.self_review_status(@admin)

    saved, review = review(own)
    assert saved, review.errors.full_messages.inspect
    own.reload
    assert own.approved?
    assert_equal @admin, own.reviewer
    assert_equal NOW + 1.hour, own.reviewed_at
    assert @admin.attendances.exists?(work_date: Date.new(2026, 11, 20))
  end

  test "有効な管理者が1人だけなら、自分の申請を却下もできる" do
    own = correction(user: @admin)
    saved, = review(own, decision: "reject", comment: "自分で取り消し")
    assert saved
    assert own.reload.rejected?
    assert_equal @admin, own.reviewer
  end

  test "有効な管理者が2人以上なら、自分の申請は承認・却下できず承認待ちのまま。他の管理者は処理できる" do
    other_admin = second_admin
    own = correction(user: @admin)
    assert_equal :forbidden, own.self_review_status(@admin)
    assert_equal :not_own, own.self_review_status(other_admin)

    %w[approve reject].each do |decision|
      saved, review = review(own, decision: decision, comment: "自分で処理")
      assert_not saved
      assert_match "ご自身の申請は他の管理者が処理します", review.errors.full_messages.first
      assert own.reload.pending?
      assert_nil own.reviewer_id
    end
    assert_not @admin.attendances.exists?(work_date: Date.new(2026, 11, 20))

    saved, = review(own, reviewer: other_admin)
    assert saved
    assert_equal other_admin, own.reload.reviewer
  end

  test "無効化された管理者・従業員は「有効な管理者」の人数に含めない" do
    own = correction(user: @admin)
    inactive_admin = second_admin(active: false)
    users(:employee) # 従業員は数えない
    assert_equal 1, User.active_admins.count
    assert_equal :allowed, own.self_review_status(@admin)

    # 2人目を有効にすると、自分の申請は処理できなくなる
    inactive_admin.update!(active: true)
    assert_equal :forbidden, own.self_review_status(@admin)
    assert_not review(own).first

    # 2人目を無効化（または従業員に変更）すると、また処理できる
    inactive_admin.update!(role: "employee")
    assert_equal :allowed, own.self_review_status(@admin)
    assert review(own).first
    assert own.reload.approved?
  end

  test "管理者でない（または無効化された）ユーザーは処理できない" do
    request = correction
    saved, review = review(request, reviewer: @employee)
    assert_not saved
    assert_includes review.errors.full_messages, "管理者の権限が無いため、承認・却下できません。"

    other_admin = second_admin
    other_admin.update!(active: false)
    saved, = review(request, reviewer: other_admin)
    assert_not saved
    assert request.reload.pending?
  end

  # ---- 承認時の再検証（スプリント7の申し送り） ----

  test "申請した後に翌日の勤務が記録され、重なるようになった申請は承認できない（理由を返す）" do
    request = correction(date: Date.new(2026, 11, 20), clock_in: "22:00", clock_out: "10:00", clock_out_day: "1")
    work(clock_in: t(21, 9), clock_out: t(21, 18)) # 申請の後に、翌日 09:00 出勤の勤務が記録された

    travel_to(NOW + 1.hour) do
      assert_equal [ "翌日（11/21(土)）の勤務の出勤（09:00）より後に退勤する内容のため承認できません（翌日の勤務と重なります）" ],
                   request.approval_blockers
    end
    saved, review = review(request)
    assert_not saved
    assert_match "翌日の勤務と重なります", review.errors.full_messages.first
    assert request.reload.pending?
    assert_not @employee.attendances.exists?(work_date: Date.new(2026, 11, 20))

    # 却下はできる
    assert review(request, decision: "reject", comment: "翌日と重なっています").first
  end

  test "隣の日の申請が先に承認されて重なった場合も、後の承認は拒否される" do
    # 11/19 の夜勤（翌 03:00 まで）と、11/20 の 02:00 出勤。別々の申請としては両方とも出せる
    night = correction(date: Date.new(2026, 11, 19), clock_in: "22:00", clock_out: "03:00", clock_out_day: "1")
    morning = correction(date: Date.new(2026, 11, 20), clock_in: "02:00", clock_out: "11:00")

    assert review(night).first
    saved, review = review(morning)
    assert_not saved
    assert_match "前日（11/19(木)）の勤務の退勤（03:00）より前に出勤する内容のため承認できません", review.errors.full_messages.first
    assert morning.reload.pending?
  end

  # ---- 退勤が空欄の申請（申請時点で勤務中だった当日の勤務） ----

  test "退勤が空欄の申請：申請後に退勤・休憩を打刻していなければ、退勤なし（勤務中）の勤怠になる" do
    request = correction(date: Date.new(2026, 11, 24), clock_in: "08:00", clock_out: "", at: t(24, 9))
    assert request.open_ended?

    saved, = review(request, at: t(24, 9, 30))
    assert saved
    attendance = @employee.attendances.find_by!(work_date: Date.new(2026, 11, 24))
    assert_equal t(24, 8), attendance.clock_in_at
    assert_nil attendance.clock_out_at
    travel_to(t(24, 9, 30)) { assert_equal :working, TimeClock.new(@employee).state }
  end

  test "退勤が空欄の申請：申請後にホームで打刻した退勤・休憩は残し、出勤と申請した休憩は申請どおりにする" do
    # 09:05 に出勤を打刻し忘れて 08:00 出勤で申請（退勤は空欄）。その後ホームで休憩・退勤を打刻した
    record = work(clock_in: t(24, 9, 5), clock_out: nil, breaks: [ [ t(24, 9, 10), t(24, 9, 20) ] ])
    request = correction(date: Date.new(2026, 11, 24), clock_in: "08:00", clock_out: "", at: t(24, 9, 30),
                         breaks: [ [ "09:10", "09:20" ] ])
    record.breaks.create!(started_at: t(24, 12), ended_at: t(24, 13))
    record.update!(clock_out_at: t(24, 18))

    saved, review = review(request, at: t(24, 19))
    assert saved, review.errors.full_messages.inspect
    record.reload
    assert_equal t(24, 8), record.clock_in_at
    assert_equal t(24, 18), record.clock_out_at
    assert_equal [ [ t(24, 9, 10), t(24, 9, 20) ], [ t(24, 12), t(24, 13) ] ], breaks_of(record)
    assert_equal "勤怠記録の出勤・休憩を申請内容どおりに更新しました（退勤は今の記録のままです）。", request.reload.approval_result_note
  end

  test "退勤が空欄の申請：申請後に休憩中なら、その休憩も残す" do
    record = work(clock_in: t(24, 9, 5), clock_out: nil)
    request = correction(date: Date.new(2026, 11, 24), clock_in: "08:00", clock_out: "", at: t(24, 9, 30))
    record.breaks.create!(started_at: t(24, 12))

    saved, = review(request, at: t(24, 12, 10))
    assert saved
    assert_equal [ [ t(24, 12), nil ] ], breaks_of(record)
    travel_to(t(24, 12, 10)) { assert_equal :on_break, TimeClock.new(@employee).state }
  end

  test "退勤が空欄の申請：翌日に勤務の記録があれば承認できない" do
    request = correction(date: Date.new(2026, 11, 23), clock_in: "22:00", clock_out: "", at: t(23, 23))
    work(clock_in: t(24, 9), clock_out: nil)
    travel_to(t(24, 10)) do
      assert_equal [ "退勤が空欄（勤務中）の申請ですが、翌日（11/24(火)）に勤務の記録があるため承認できません" ], request.approval_blockers
    end
    assert_not review(request, at: t(24, 10)).first
    assert request.reload.pending?
  end

  test "退勤が空欄の申請：残す退勤が、申請で早めた出勤から24時間を超えるなら承認できない" do
    # 11/23 10:00 に出勤を打刻（実際は 08:00 出勤）→ 08:00 で申請（退勤は空欄）→ 翌 09:00 にホームで退勤
    record = work(clock_in: t(23, 10), clock_out: nil)
    request = correction(date: Date.new(2026, 11, 23), clock_in: "08:00", clock_out: "", at: t(23, 10, 30))
    record.update!(clock_out_at: t(24, 9))

    blockers = travel_to(t(24, 9, 30)) { request.approval_blockers }
    assert_equal [ "申請した後に記録された退勤（翌 09:00）が、申請の出勤から24時間を超えるため承認できません" ], blockers
    assert_not review(request, at: t(24, 9, 30)).first
    assert_equal t(23, 10), record.reload.clock_in_at
  end

  # ---- その他 ----

  test "submit はロック競合でも例外にせず、false とエラーを返す" do
    request = @employee.attendance_correction_requests.new(target_date: Date.new(2026, 11, 20), clock_in_time: "09:00",
                                                           clock_out_time: "18:00", reason: "忘れました")
    request.stub(:save, -> { raise busy_error }) do
      assert_not request.submit
    end
    assert_match "他の操作と同時に送信されたため、保存できませんでした", request.errors.full_messages.first
  end

  private

  # SQLite が返す「database is locked」と同じ形の例外（原因が SQLite3::BusyException の StatementInvalid）
  def busy_error
    raise SQLite3::BusyException, "database is locked"
  rescue SQLite3::BusyException
    begin
      raise ActiveRecord::StatementInvalid, "SQLite3::BusyException: database is locked"
    rescue ActiveRecord::StatementInvalid => error
      error
    end
  end
end
