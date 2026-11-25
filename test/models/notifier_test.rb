require "test_helper"
require "minitest/mock"

# アプリ内通知（F16）：出来事ごとに、誰に・どんな通知が届くか（届かない場合も）。通知が作れなくても元の処理は失敗しないこと
class NotifierTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include Rails.application.routes.url_helpers

  # 2026-11-25 は水曜日
  NOW = Time.zone.local(2026, 11, 25, 10, 0)
  WEEK = Date.new(2026, 11, 23)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
  end

  teardown { travel_back }

  def d(day)
    Date.new(2026, 11, day)
  end

  def second_admin(active: true, email: "admin2@example.com")
    User.create!(name: "管理 二郎", email: email, password: "password123", role: "admin",
                 hired_on: Date.new(2021, 4, 1), active: active)
  end

  def correction!(user: @employee, date: d(20))
    request = user.attendance_correction_requests.new(target_date: date, clock_in_time: "09:00", clock_out_time: "18:00",
                                                      reason: "打刻を忘れたため")
    assert request.submit, request.errors.full_messages.inspect
    request
  end

  def leave!(user: @employee, from: d(30), to: d(30), type: "paid")
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: "full_day", reason: "私用のため")
    assert leave.submit, leave.errors.full_messages.inspect
    leave
  end

  def approved_leave!(user: @employee, **options)
    leave = leave!(user: user, **options)
    review!(leave, decision: "approve")
    leave.reload
  end

  def review!(request, decision:, reviewer: @admin, comment: nil)
    review = ApprovalReview.new(approval_request: ApprovalRequest.find(request.id), reviewer: reviewer, decision: decision, comment: comment)
    assert review.save, review.errors.full_messages.inspect
    review.approval_request
  end

  def notifications_for(user)
    Notification.where(recipient: user).order(:id).to_a
  end

  # ---- 新しい申請 → 管理者 ----

  test "打刻修正・休暇・取消申請のどれを出しても、有効な管理者全員に「新しい申請」が届く（無効な管理者・従業員には届かない）" do
    admin2 = second_admin
    inactive_admin = second_admin(active: false, email: "admin3@example.com")
    leave = approved_leave!(from: d(30), to: d(30))
    Notification.delete_all

    correction = correction!
    cancellation = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "予定が変わったため")
    assert cancellation.submit
    leave2 = leave!(from: d(27), to: d(27), type: "special")

    [ correction, cancellation, leave2 ].each do |request|
      notes = Notification.where(subject: request, kind: "request_submitted").to_a
      assert_equal [ @admin.id, admin2.id ].sort, notes.map(&:recipient_id).sort, request.class.name
      note = notes.first
      assert_equal admin_approval_request_path(request), note.path
      assert_equal @employee, note.actor
      assert_match "従業 花子 さんから#{request.kind_label}の申請が届きました", note.title
      assert_match "理由：", note.body
    end
    assert_equal 0, Notification.where(recipient: [ @employee, inactive_admin ]).count
    assert_includes Notification.find_by(subject: leave2, recipient: @admin).body, "特別休暇（全日）・1日"
  end

  test "管理者が自分の申請を出したときは、本人には届かず、他の有効な管理者だけに届く。管理者が1人だけなら誰にも届かない" do
    correction!(user: @admin, date: d(19))
    assert_equal 0, Notification.count, "有効な管理者が本人だけ：自分で出した申請なので通知しない（承認の画面の件数には出る）"

    admin2 = second_admin
    request = correction!(user: @admin, date: d(18))
    assert_equal [ admin2.id ], Notification.where(subject: request).pluck(:recipient_id)
  end

  test "保存できなかった申請では、通知は作られない" do
    request = @employee.attendance_correction_requests.new(target_date: d(20), clock_in_time: "09:00", clock_out_time: "18:00", reason: "")
    assert_not request.submit
    assert_equal 0, Notification.count
  end

  # ---- 承認・却下 → 申請者 ----

  test "打刻修正・休暇・取消申請の承認と却下で、申請者に結果が届く（コメント・処理した管理者・申請の詳細へのリンク）" do
    correction = correction!
    review!(correction, decision: "approve", comment: "確認しました")
    note = Notification.find_by!(recipient: @employee, subject: correction)
    assert_equal "request_approved", note.kind
    assert_equal "打刻修正の申請が承認されました（11/20(金)）", note.title
    assert_match "管理 太郎 さんが承認しました。", note.body
    assert_match "コメント：確認しました", note.body
    assert_equal approval_request_path(correction), note.path
    assert_equal @admin, note.actor

    rejected = correction!(date: d(19))
    review!(rejected, decision: "reject", comment: "時刻を確認してください")
    note = Notification.find_by!(recipient: @employee, subject: rejected)
    assert_equal "request_rejected", note.kind
    assert_match "却下されました", note.title
    assert_match "コメント：時刻を確認してください", note.body

    leave = leave!(from: d(30), to: d(30))
    review!(leave, decision: "approve")
    assert_equal "request_approved", Notification.find_by!(recipient: @employee, subject: leave).kind
    rejected_leave = leave!(from: d(27), to: d(27), type: "special")
    review!(rejected_leave, decision: "reject", comment: "人員が足りないため")
    assert_equal "request_rejected", Notification.find_by!(recipient: @employee, subject: rejected_leave).kind

    cancellation = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "予定が変わったため")
    assert cancellation.submit
    review!(cancellation, decision: "approve")
    note = Notification.find_by!(recipient: @employee, subject: cancellation)
    assert_equal "休暇取消の申請が承認されました（11/30(月)）", note.title
    assert_match "休暇は取り消されました。", note.body
  end

  test "管理者が1人だけで自分の申請を自己承認したときは、自分には結果を送らない" do
    request = correction!(user: @admin, date: d(19))
    review!(request, decision: "approve")
    assert_equal 0, Notification.where(recipient: @admin).count
  end

  test "承認できなかった（処理済みなど）ときは、結果の通知は増えない" do
    request = correction!
    review!(request, decision: "approve")
    review = ApprovalReview.new(approval_request: ApprovalRequest.find(request.id), reviewer: @admin, decision: "reject", comment: "x")
    assert_not review.save
    assert_equal 1, Notification.where(recipient: @employee).count
  end

  # ---- 管理者の直接取消 → 休暇の本人 ----

  test "管理者が休暇を直接取り消すと、本人に1件だけ届く（承認待ちの取消申請が処理済みになったことも書く）" do
    leave = approved_leave!(from: d(30), to: d(30))
    cancellation = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "予定が変わったため")
    assert cancellation.submit
    Notification.delete_all

    direct = LeaveDirectCancellation.new(leave_request: LeaveRequest.find(leave.id), admin: @admin, reason: "本人から電話があったため")
    assert direct.save, direct.errors.full_messages.inspect
    notes = notifications_for(@employee)
    assert_equal 1, notes.size
    note = notes.first
    assert_equal "leave_cancelled_by_admin", note.kind
    assert_equal "休暇が管理者により取り消されました（11/30(月)）", note.title
    assert_match "管理 太郎 さんが 11/30(月) の有給（全日）を取り消しました。", note.body
    assert_match "有給休暇の残日数に1日戻りました。", note.body
    assert_match "出していた取消申請は、この取消で処理済みになりました。", note.body
    assert_match "理由：本人から電話があったため", note.body
    assert_equal approval_request_path(leave), note.path
  end

  test "管理者が1人だけで自分の休暇を直接取り消したときは、自分には送らない" do
    leave = approved_leave!(user: @admin, from: d(30), to: d(30))
    Notification.delete_all
    direct = LeaveDirectCancellation.new(leave_request: LeaveRequest.find(leave.id), admin: @admin, reason: "予定変更")
    assert direct.save, direct.errors.full_messages.inspect
    assert_equal 0, Notification.count
  end

  # ---- シフトの公開・変更 → 変わった本人だけ ----

  def shift!(date, user: @employee, start_time: "9:00", end_time: "18:00")
    Shift.create!(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: 60,
                  created_by: @admin, updated_by: @admin)
  end

  def publish!(week = WEEK, admin: @admin)
    publication = ShiftWeekPublication.new(week_start: week, admin: admin)
    assert publication.save, publication.errors.full_messages.inspect
    publication
  end

  test "週を公開すると、シフトがある従業員に「公開」が届く。再公開では、変わった本人にだけ「変更」が届く" do
    other = User.create!(name: "社員 三郎", email: "saburo@example.com", password: "password123", hired_on: Date.new(2022, 4, 1))
    first = shift!(WEEK)
    shift!(WEEK + 1)
    shift!(WEEK + 2, user: other)

    publish!
    employee_note = Notification.find_by!(recipient: @employee)
    assert_equal "shift_published", employee_note.kind
    assert_equal "シフトが公開されました（11/23〜11/29）", employee_note.title
    assert_match "追加：11/23(月)、11/24(火)", employee_note.body
    assert_equal shifts_path(month: "2026-11"), employee_note.path
    assert_equal 1, Notification.where(recipient: other, kind: "shift_published").count
    assert_equal 0, Notification.where(recipient: @admin).count, "公開した管理者（シフトなし）には届かない"

    # 花子のシフトだけを変えて再公開 → 花子にだけ「変更」
    first.reload.update!(start_time: "10:00")
    publish!
    assert_equal 1, Notification.where(recipient: other).count, "変わっていない三郎には、再公開の通知は届かない"
    changed = Notification.where(recipient: @employee).order(:id).last
    assert_equal "shift_changed", changed.kind
    assert_equal "シフトが変更されました（11/23〜11/29）", changed.title
    assert_match "変更：11/23(月)", changed.body
  end

  test "公開済みのシフトの削除は本人に「変更」として届き、下書きのまま削除したシフトは届かない" do
    published = shift!(WEEK + 3)
    publish!
    Notification.delete_all

    published.reload.remove!(by: @admin)
    draft = shift!(WEEK + 4)
    draft.remove!(by: @admin) if Shift.exists?(draft.id)
    shift!(WEEK + 5, user: users(:admin)) # 公開した管理者自身のシフト
    publish!

    note = Notification.find_by!(recipient: @employee)
    assert_equal "shift_changed", note.kind
    assert_match "削除：11/26(木)", note.body
    assert_no_match "11/27", note.body, "下書きのまま消したシフトは、本人に見えていなかったので書かない"
    assert_equal 0, Notification.where(recipient: @admin).count, "自分で公開した自分のシフトは通知しない"
  end

  test "下書きの削除しか無い公開では、誰にも届かない" do
    draft = shift!(WEEK + 4)
    draft.update_columns(removed_at: NOW) # 削除予定の下書き（公開されたことがない）
    publish!
    assert_equal 0, Notification.count
  end

  # ---- 有給の付与 → 本人 ----

  test "有給を付与すると本人に届き、管理者が自分に付与したときは届かない" do
    grant = PaidLeaveGrant.create!(user: @employee, granted_on: d(25), days: "10", granted_by: @admin)
    Notifier.paid_leave_granted(grant)
    note = Notification.find_by!(recipient: @employee)
    assert_equal "paid_leave_granted", note.kind
    assert_equal "有給休暇が10日付与されました", note.title
    assert_match "2026年11月25日(水) 付与・2028年11月25日(土) まで有効です。", note.body
    assert_match "今の残日数は", note.body
    assert_equal leave_requests_path, note.path

    own = PaidLeaveGrant.create!(user: @admin, granted_on: d(25), days: "5", granted_by: @admin)
    Notifier.paid_leave_granted(own)
    assert_equal 0, Notification.where(recipient: @admin).count
  end

  # ---- 失敗しても元の処理は成功する ----

  test "通知が作れなくても（例外が起きても）、承認・申請・取消・公開は成功し、例外は外に出ない" do
    boom = ->(*) { raise ActiveRecord::StatementInvalid, "disk I/O error" }
    Notification.stub(:create!, boom) do
      request = correction!
      assert request.persisted?
      approved = review!(request, decision: "approve")
      assert approved.approved?
      assert Attendance.exists?(user: @employee, work_date: d(20)), "承認の処理（勤怠の更新）は取り消されない"

      leave = approved_leave!(from: d(30), to: d(30))
      direct = LeaveDirectCancellation.new(leave_request: LeaveRequest.find(leave.id), admin: @admin, reason: "依頼")
      assert direct.save
      assert leave.reload.cancelled?

      shift!(WEEK)
      publish!
      assert_equal :published, Shift.find_by(user: @employee, work_date: WEEK).state
    end
    assert_equal 0, Notification.count
  end

  test "管理者全員分の通知の途中で失敗したら、その出来事の通知はまとめて作られない（一部の人にだけ届かない）" do
    second_admin
    calls = 0
    original = Notification.method(:create!)
    flaky = lambda do |**attributes|
      calls += 1
      raise ActiveRecord::StatementInvalid, "2人目で失敗" if calls == 2

      original.call(**attributes)
    end
    Notification.stub(:create!, flaky) do
      request = correction!
      assert request.persisted?
    end
    assert_equal 0, Notification.count
  end

  test "無効な従業員には送らない" do
    inactive = users(:inactive_employee)
    grant = PaidLeaveGrant.create!(user: inactive, granted_on: d(25), days: "10", granted_by: @admin)
    Notifier.paid_leave_granted(grant)
    assert_equal 0, Notification.count
  end
end
