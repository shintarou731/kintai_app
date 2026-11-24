require "test_helper"
require "minitest/mock"

# 管理者による承認済み休暇の直接取消（F9 の追加分。LeaveDirectCancellation）
class LeaveDirectCancellationTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-24 は火曜日
  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @employee = users(:employee)
    @admin = users(:admin)
    travel_to NOW
  end

  teardown { travel_back }

  def d(day)
    Date.new(2026, 11, day)
  end

  def leave!(user: @employee, from: d(26), to: d(27), type: "paid", part: "full_day", status: "approved")
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: part, reason: "私用のため")
    assert leave.submit, leave.errors.full_messages.inspect
    leave.update_columns(status: status, reviewer_id: @admin.id, reviewed_at: NOW - 1.day) unless status == "pending"
    leave.reload
  end

  def cancellation!(leave, user: @employee)
    request = user.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "予定が変わったため")
    assert request.submit, request.errors.full_messages.inspect
    request
  end

  def cancel(leave, admin: @admin, reason: "本人から依頼があったため")
    cancellation = LeaveDirectCancellation.new(leave_request: LeaveRequest.find(leave.id), admin: admin, reason: reason)
    [ cancellation.save, cancellation ]
  end

  def second_admin
    User.create!(name: "管理 二郎", email: "admin2@example.com", password: "password123", role: "admin",
                 hired_on: Date.new(2021, 4, 1))
  end

  # ---- 取り消せる場合 ----

  test "開始日が未来・当日・過去・期間の途中のどの承認済み休暇も、理由を入れて直接取り消せる" do
    future = leave!(from: d(26), to: d(27))
    today = leave!(from: d(24), to: d(24), type: "special", part: "morning")
    past = leave!(from: d(16), to: d(18), type: "absence")
    started = leave!(from: d(19), to: d(20))
    started.update_columns(end_date: d(25)) # 期間の途中（開始日を過ぎ、終了日は未来）

    [ future, today, past, started ].each do |leave|
      saved, cancellation = cancel(leave, reason: "  電話で依頼があったため  ")
      assert saved, cancellation.errors.full_messages.inspect

      leave.reload
      assert leave.approved?, "申請の状態は承認済みのまま（取消済みは cancelled_at で表す）"
      assert leave.cancelled?
      assert leave.directly_cancelled?
      assert_not leave.effective?
      assert_equal NOW, leave.cancelled_at
      assert_equal @admin, leave.cancelled_by
      assert_equal "電話で依頼があったため", leave.cancellation_reason
      assert_equal NOW, leave.last_processed_at
    end
    assert_equal 0, LeaveRequest.effective.where(user: @employee).count
  end

  test "取り消した休暇は勤怠履歴（月度の休暇）から消え、同じ期間にもう一度申請できる" do
    leave = leave!(from: d(24), to: d(24))
    period = WorkRules.current.period_containing(d(24))
    assert_equal [ leave.id ], MonthlyAttendance.new(@employee, period: period).leaves_on(d(24)).map(&:id)

    saved, = cancel(leave)
    assert saved

    assert_empty MonthlyAttendance.new(@employee, period: period).leaves_on(d(24))
    again = @employee.leave_requests.new(target_date: d(24), end_date: d(24), leave_type: "paid", day_part: "full_day", reason: "再申請")
    assert again.submit, again.errors.full_messages.inspect
  end

  # ---- 取り消せない場合 ----

  test "理由が空（空白だけ）なら取り消せず、休暇は承認済みのまま" do
    leave = leave!

    [ "", "   ", nil ].each do |reason|
      saved, cancellation = cancel(leave, reason: reason)
      assert_not saved
      assert_equal [ "取消の理由を入力してください" ], cancellation.errors.full_messages
    end
    assert leave.reload.effective?
    assert_nil leave.cancelled_by_id
  end

  test "理由が長すぎると取り消せない" do
    leave = leave!
    saved, cancellation = cancel(leave, reason: "あ" * (ApprovalRequest::REASON_MAX_LENGTH + 1))

    assert_not saved
    assert_match(/取消の理由は500文字以内/, cancellation.errors.full_messages.first)
    assert leave.reload.effective?
  end

  test "承認待ち・却下・取り下げの休暇は取り消せない" do
    { "pending" => "承認待ち", "rejected" => "却下", "withdrawn" => "取り下げ" }.each_with_index do |(status, label), index|
      leave = leave!(from: d(26) + (index * 7), to: d(26) + (index * 7), status: status)
      saved, cancellation = cancel(leave)

      assert_not saved
      assert_equal [ "この休暇は「#{label}」のため取り消せません（承認済みの休暇だけ取り消せます）。" ], cancellation.errors.full_messages
      assert_nil leave.reload.cancelled_at
      assert_equal status, leave.status
    end
  end

  test "すでに取り消された休暇は取り消せず、最初の取消の記録が残る（二重に取り消さない）" do
    leave = leave!
    assert cancel(leave, reason: "1回目").first
    first_at = leave.reload.cancelled_at

    travel 5.minutes do
      saved, cancellation = cancel(leave, admin: second_admin, reason: "2回目")
      assert_not saved
      assert_equal [ "この休暇はすでに取り消されています。" ], cancellation.errors.full_messages
    end
    leave.reload
    assert_equal first_at, leave.cancelled_at
    assert_equal @admin, leave.cancelled_by
    assert_equal "1回目", leave.cancellation_reason
  end

  test "取消申請の承認で取り消された休暇は、直接取り消せない" do
    leave = leave!
    request = cancellation!(leave)
    assert ApprovalReview.new(approval_request: request, reviewer: @admin, decision: "approve").save

    saved, cancellation = cancel(leave)
    assert_not saved
    assert_equal [ "この休暇はすでに取り消されています。" ], cancellation.errors.full_messages
    assert_nil leave.reload.cancelled_by_id
  end

  test "従業員ロール・無効化された管理者は取り消せない" do
    leave = leave!
    inactive_admin = second_admin
    inactive_admin.update_columns(active: false)

    [ @employee, users(:inactive_employee), inactive_admin ].each do |user|
      saved, cancellation = cancel(leave, admin: user)
      assert_not saved
      assert_equal [ "管理者の権限が無いため、休暇を取り消せません。" ], cancellation.errors.full_messages
    end
    assert leave.reload.effective?
  end

  test "締め済み（F14）の月度にかかる休暇は取り消せない（ClosedPeriodGuard で判定する）" do
    leave = leave!(from: d(24), to: d(24))
    checked = []
    guard = lambda do |from, to|
      checked << [ from, to ]
      "2026年11月度"
    end

    ClosedPeriodGuard.stub(:closed_period_label, guard) do
      assert_equal [ "この休暇は締め済みの月度（2026年11月度）にかかるため、取り消せません。" ],
                   leave.direct_cancellation_blockers(@admin)
      saved, cancellation = cancel(leave)
      assert_not saved
      assert_equal [ "この休暇は締め済みの月度（2026年11月度）にかかるため、取り消せません。" ], cancellation.errors.full_messages
    end
    assert_includes checked, [ d(24), d(24) ]
    assert leave.reload.effective?
  end

  test "締めが未実装の今は、締め済みの月度は無い" do
    assert_nil ClosedPeriodGuard.closed_period_label(d(1), d(30))
  end

  # ---- 自己取消（F8 の自己承認ルールと同じ） ----

  test "有効な管理者が2人以上なら、自分の休暇は直接取り消せない" do
    other = second_admin
    own = leave!(user: @admin)

    assert_equal :forbidden, own.self_review_status(@admin)
    saved, cancellation = cancel(own)
    assert_not saved
    assert_equal [ "ご自身の休暇は他の管理者が取り消します（有効な管理者が2名いるため、ご自身では取り消せません）。" ],
                 cancellation.errors.full_messages
    assert own.reload.effective?

    # 他の管理者なら取り消せる
    saved, = cancel(own, admin: other)
    assert saved
    assert_equal other, own.reload.cancelled_by
  end

  test "有効な管理者が1人だけなら、自分の休暇も直接取り消せ、取り消した管理者として本人が記録される" do
    own = leave!(user: @admin)

    assert_equal 1, User.active_admins.count
    assert_equal :allowed, own.self_review_status(@admin)
    saved, cancellation = cancel(own)
    assert saved, cancellation.errors.full_messages.inspect
    assert_equal @admin, own.reload.cancelled_by
  end

  test "管理者の人数が変わると、自分の休暇を取り消せるかどうかも切り替わる" do
    own = leave!(user: @admin)
    other = second_admin
    assert_not cancel(own).first

    other.update_columns(active: false) # 2人目を無効化 → 有効な管理者は1人
    assert cancel(own).first
  end

  # ---- 承認待ちの取消申請との関係 ----

  test "承認待ちの取消申請がある休暇を直接取り消すと、その取消申請は「直接取消で処理済み」になり、承認待ちから消える" do
    leave = leave!
    request = cancellation!(leave)
    assert_includes ApprovalRequest.pending, request

    saved, cancellation = cancel(leave)
    assert saved, cancellation.errors.full_messages.inspect
    assert_equal [ request.id ], cancellation.closed_cancellation_requests.map(&:id)

    request.reload
    assert request.approved?
    assert request.closed_by_direct_cancellation?
    assert_equal @admin, request.reviewer
    assert_equal NOW, request.reviewed_at
    assert_equal "管理 太郎 さんが休暇を直接取り消したため、この取消申請は処理済みになりました。", request.review_comment
    assert_not_includes ApprovalRequest.pending, request
    assert_nil leave.reload.pending_cancellation
    assert leave.directly_cancelled?
  end

  test "直接取消で処理済みになった取消申請は、後から承認・却下・取り下げできない（二重に処理されない）" do
    leave = leave!
    request = cancellation!(leave)
    assert cancel(leave).first
    cancelled_at = leave.reload.cancelled_at

    travel 1.minute do
      %w[approve reject].each do |decision|
        review = ApprovalReview.new(approval_request: ApprovalRequest.find(request.id), reviewer: second_admin_or_create,
                                    decision: decision, comment: "確認")
        assert_not review.save
        assert_match(/すでに.*処理済み/, review.errors.full_messages.first)
      end
      assert_not ApprovalRequest.find(request.id).withdraw
    end
    assert_equal cancelled_at, leave.reload.cancelled_at
    assert request.reload.approved?
    assert_equal 1, LeaveCancellationRequest.where(leave_request: leave).count
  end

  test "取消申請の承認の直前（ロックを取った後）に休暇が取り消されていたら、承認は失敗して二重に取り消さない" do
    leave = leave!
    request = cancellation!(leave)
    # approval_blockers の確かめの後に、直接取消が先に終わった状態を作る
    leave.update_columns(cancelled_at: NOW, cancelled_by_id: @admin.id, cancellation_reason: "先に取消")

    error = assert_raises(ActiveRecord::RecordInvalid) { request.apply_approval!(now: NOW + 1.minute) }
    assert_match(/すでに取り消されています/, error.message)
    assert_equal NOW, leave.reload.cancelled_at
  end

  test "却下・取り下げ済みの取消申請は、直接取消で書き換えない" do
    leave = leave!
    rejected = cancellation!(leave)
    assert ApprovalReview.new(approval_request: rejected, reviewer: @admin, decision: "reject", comment: "業務の都合").save

    saved, cancellation = cancel(leave)
    assert saved
    assert_empty cancellation.closed_cancellation_requests
    assert rejected.reload.rejected?
    assert_not rejected.closed_by_direct_cancellation?
  end

  # ---- 同時実行・ロック競合 ----

  test "ロック競合のときは例外にせず、エラーとして返し、休暇は変わらない" do
    leave = leave!
    LeaveRequest.stub(:lock, -> { raise busy_error }) do
      saved, cancellation = cancel(leave)
      assert_not saved
      assert_equal [ DatabaseLockError::MESSAGE ], cancellation.errors.full_messages
    end
    assert leave.reload.effective?
  end

  private

  def second_admin_or_create
    User.find_by(email: "admin2@example.com") || second_admin
  end

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
