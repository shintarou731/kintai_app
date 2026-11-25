require "test_helper"

# 休暇申請・取消申請の承認・却下（F8 の承認処理に F9 の申請が乗ること）と、取消申請の入力の確かめ
class LeaveApprovalTest < ActiveSupport::TestCase
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

  def leave!(user: @employee, from: d(26), to: d(27), type: "paid", part: "full_day")
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: part, reason: "私用のため")
    assert leave.submit, leave.errors.full_messages.inspect
    leave
  end

  def review(request, reviewer: @admin, decision: "approve", comment: nil)
    review = ApprovalReview.new(approval_request: ApprovalRequest.find(request.id), reviewer: reviewer, decision: decision,
                                comment: comment)
    [ review.save, review ]
  end

  def approved_leave!(**options)
    leave = leave!(**options)
    saved, review = review(leave)
    assert saved, review.errors.full_messages.inspect
    leave.reload
  end

  def cancellation!(leave, user: @employee, reason: "予定が変わったため")
    request = user.leave_cancellation_requests.new(leave_request_id: leave.id, reason: reason)
    assert request.submit, request.errors.full_messages.inspect
    request
  end

  def second_admin
    User.create!(name: "管理 二郎", email: "admin2@example.com", password: "password123", role: "admin",
                 hired_on: Date.new(2021, 4, 1))
  end

  # ---- 休暇申請の承認・却下 ----

  test "休暇申請を承認すると承認済みになり、有効な休暇として扱われる" do
    leave = leave!
    saved, review = review(leave, comment: "了解しました")

    assert saved, review.errors.full_messages.inspect
    leave.reload
    assert leave.approved?
    assert leave.effective?
    assert_equal @admin, leave.reviewer
    assert_equal NOW, leave.reviewed_at
    assert_equal "了解しました", leave.review_comment
    assert_includes LeaveRequest.effective, leave
    assert_equal "勤怠履歴の該当日に「有給（全日）」と表示されます。有給休暇の残日数から2日引きました。", leave.approval_result_note
  end

  test "休暇申請を却下するとコメントが必須で、休暇は有効にならない" do
    leave = leave!
    saved, review = review(leave, decision: "reject")
    assert_not saved
    assert_includes review.errors.full_messages, "コメントを入力してください（却下するときは、理由をコメントに書いてください）"

    saved, = review(leave, decision: "reject", comment: "繁忙期のため")
    assert saved
    assert leave.reload.rejected?
    assert_not_includes LeaveRequest.effective, leave
  end

  test "承認する直前に、承認済みの休暇と重なっていれば承認できず、承認待ちのまま" do
    leave = leave!(from: d(26), to: d(27))
    other = leave!(from: d(30), to: d(30))
    # 申請時の確かめを通り抜けた重なりを想定して、もう一方を 11/27 の承認済みに変える
    other.update_columns(target_date: d(27), end_date: d(27), status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)

    saved, review = review(leave)
    assert_not saved
    assert_equal [ "承認済みの 11/27(金) の有給休暇（全日） と期間が重なるため承認できません" ], review.errors.full_messages
    assert leave.reload.pending?

    # 却下はできる
    saved, = review(leave, decision: "reject", comment: "重なっています")
    assert saved
  end

  # ---- 自己承認ルール（打刻修正申請と同じ） ----

  test "有効な管理者が2人以上いると、管理者は自分の休暇申請・取消申請を承認・却下できない" do
    other_admin = second_admin
    own = leave!(user: @admin)

    saved, review = review(own)
    assert_not saved
    assert_match "ご自身の申請は他の管理者が処理します", review.errors.full_messages.first
    assert own.reload.pending?

    saved, = review(own, reviewer: other_admin)
    assert saved

    cancel = cancellation!(own.reload, user: @admin)
    saved, review = review(cancel, decision: "reject", comment: "自分で却下")
    assert_not saved
    assert_match "ご自身の申請は他の管理者が処理します", review.errors.full_messages.first
    assert cancel.reload.pending?
  end

  test "有効な管理者が1人だけなら、自分の休暇申請も承認でき、処理者として本人が記録される" do
    own = leave!(user: @admin)
    saved, = review(own)

    assert saved
    assert own.reload.approved?
    assert_equal @admin, own.reviewer
  end

  # ---- 取消申請 ----

  test "未来の承認済みの休暇には取消申請を出せ、承認されると休暇が取り消される" do
    leave = approved_leave!
    cancel = cancellation!(leave)

    assert cancel.pending?
    assert_equal leave.target_date, cancel.target_date
    assert_equal "11/26(木)〜11/27(金)", cancel.target_label
    assert_equal "休暇取消", cancel.kind_label
    assert_equal cancel, leave.reload.pending_cancellation
    assert leave.effective?, "取消申請中も、承認されるまでは休暇は有効"

    travel_to(NOW + 1.hour) do
      saved, review = review(cancel)
      assert saved, review.errors.full_messages.inspect
    end
    assert cancel.reload.approved?
    leave.reload
    assert leave.cancelled?
    assert_equal NOW + 1.hour, leave.cancelled_at
    assert leave.approved?, "休暇申請の状態は「承認済み」のまま（取消済みとして扱う）"
    assert_not leave.effective?
    assert_not_includes LeaveRequest.effective, leave
    assert_not_includes LeaveRequest.blocking, leave
  end

  test "取消申請が却下されると、休暇は有効のまま。取り下げても有効のまま" do
    leave = approved_leave!
    cancel = cancellation!(leave)
    saved, = review(cancel, decision: "reject", comment: "代わりの人がいないため")
    assert saved
    assert leave.reload.effective?

    second = cancellation!(leave, reason: "もう一度お願いします")
    assert second.withdraw
    assert leave.reload.effective?
    assert_equal "休暇は有効のままです。", second.withdrawal_result_note
  end

  test "取り消された休暇の期間には、もう一度休暇を申請できる" do
    leave = approved_leave!
    cancel = cancellation!(leave)
    assert review(cancel).first

    assert leave!(from: d(27), to: d(27), part: "morning").pending?
  end

  test "当日・過去の承認済みの休暇には取消申請を出せない" do
    today = approved_leave!(from: d(24), to: d(24))
    past = approved_leave!(from: d(20), to: d(23), type: "absence")
    started = approved_leave!(from: d(25), to: d(30), type: "special")
    started.update_columns(target_date: d(19)) # 期間の途中（開始日を過ぎた）

    [ today, past, started ].each do |leave|
      request = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "取り消したい")
      assert_not request.submit
      assert_equal [ "開始日が今日または過去の休暇は、取消申請できません。取消は管理者に依頼してください（管理者が直接取り消します）" ],
                   request.errors.full_messages
    end
  end

  test "承認待ち・却下・取消済みの休暇、他の人の休暇には取消申請を出せない" do
    pending = leave!(from: d(26), to: d(26))
    request = @employee.leave_cancellation_requests.new(leave_request_id: pending.id, reason: "x")
    assert_not request.submit
    assert_match "承認済みの休暇だけ取消申請できます", request.errors.full_messages.first

    others = approved_leave!(user: @admin, from: d(27), to: d(27))
    request = @employee.leave_cancellation_requests.new(leave_request_id: others.id, reason: "x")
    assert_not request.submit
    assert_equal [ "取り消す休暇が見つかりません" ], request.errors.full_messages

    request = @employee.leave_cancellation_requests.new(reason: "x")
    assert_not request.submit
    assert_includes request.errors.full_messages, "取り消す休暇を入力してください"

    leave = approved_leave!(from: d(30), to: d(30))
    assert review(cancellation!(leave)).first
    request = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "x")
    assert_not request.submit
    assert_equal [ "この休暇はすでに取り消されています" ], request.errors.full_messages
  end

  test "1つの休暇に承認待ちの取消申請は1件まで。理由は必須" do
    leave = approved_leave!
    request = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: " ")
    assert_not request.submit
    assert_equal [ "取消の理由を入力してください" ], request.errors.full_messages

    cancellation!(leave)
    request = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "二重")
    assert_not request.submit
    assert_equal [ "この休暇にはすでに承認待ちの取消申請があります" ], request.errors.full_messages
  end

  test "取消申請の承認の直前に、休暇がすでに取り消されていれば承認できない" do
    leave = approved_leave!
    cancel = cancellation!(leave)
    leave.update_columns(cancelled_at: NOW) # 別の経路で取り消された状態

    saved, review = review(cancel)
    assert_not saved
    assert_equal [ "取り消す休暇は、すでに取り消されています" ], review.errors.full_messages
    assert cancel.reload.pending?
  end

  test "処理が遅れて開始日を過ぎた取消申請も承認でき、承認画面で知らせるための判定がある" do
    leave = approved_leave!(from: d(25), to: d(25))
    cancel = cancellation!(leave)

    travel_to(Time.zone.local(2026, 11, 26, 9)) do
      assert cancel.target_passed?
      assert review(cancel).first
    end
    assert leave.reload.cancelled?
  end

  # ---- 承認待ちのバッジの件数（自己承認ルールに従う） ----

  test "承認待ちの件数は、有効な管理者が2人以上なら自分の申請を数えない" do
    leave!(user: @admin)
    leave!(user: @employee)
    assert_equal 2, ApprovalRequest.actionable_by(@admin).count, "管理者が1人なら自分の申請も処理できる"

    other_admin = second_admin
    assert_equal 1, ApprovalRequest.actionable_by(@admin).count
    assert_equal 2, ApprovalRequest.actionable_by(other_admin).count
  end
end
