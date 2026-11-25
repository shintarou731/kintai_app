require "test_helper"

# 有給休暇の申請・承認・取消と残日数（F10）。付与の無い従業員を作って確かめる（フィクスチャの付与の影響を受けない）。
# 今日は 2026-11-24(火) に固定する。11/23 は勤労感謝の日（月・祝日）。
class PaidLeaveBalanceTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 24, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @user = User.create!(name: "有給 太郎", email: "paid-balance@example.com", password: "password123", hired_on: Date.new(2025, 4, 1))
  end

  teardown { travel_back }

  def d(month, day, year: 2026)
    Date.new(year, month, day)
  end

  def grant!(days, granted_on: d(4, 1), expires_on: nil)
    PaidLeaveGrant.create!(user: @user, granted_by: @admin, granted_on: granted_on, days: days.to_s, expires_on: expires_on)
  end

  def build_leave(from, to = from, type: "paid", part: "full_day")
    @user.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: part, reason: "私用のため")
  end

  def leave!(from, to = from, **options)
    leave = build_leave(from, to, **options)
    assert leave.submit, leave.errors.full_messages.inspect
    leave
  end

  def approve!(leave)
    review = ApprovalReview.new(approval_request: ApprovalRequest.find(leave.id), reviewer: @admin, decision: "approve")
    assert review.save, review.errors.full_messages.inspect
    leave.reload
  end

  def account
    PaidLeaveAccount.new(@user.reload)
  end

  test "承認されると残日数が減り（休日を除く）、取消申請が承認されると戻る" do
    grant!(10)
    leave = leave!(d(11, 27), d(11, 30)) # 金・土・日・月 → 2日
    assert_equal 10, account.balance
    assert_equal 8, account.requestable

    approve!(leave)
    assert_equal 8, account.balance
    assert_equal 0, account.pending_days

    cancel = @user.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "予定が変わったため")
    assert cancel.submit
    approve!(cancel)
    assert leave.reload.cancelled?
    assert_equal 10, account.balance
  end

  test "管理者が直接取り消すと、取り消した日数分だけ残日数が戻る（開始日を過ぎた休暇も）" do
    grant!(10)
    leave = approve!(leave!(d(11, 20), d(11, 24))) # 11/21・22・23 を除いて2日
    assert_equal 8, account.balance

    cancellation = LeaveDirectCancellation.new(leave_request: leave, admin: @admin, reason: "勤務していたため")
    assert cancellation.save, cancellation.errors.full_messages.inspect
    assert_equal 10, account.balance
  end

  test "半休は0.5日として残日数から引く" do
    grant!(1)
    approve!(leave!(d(11, 26), part: "morning"))
    assert_equal Rational(1, 2), account.balance
    leave!(d(11, 27), part: "afternoon")
    assert_equal 0, account.requestable
  end

  test "残日数ちょうどの申請はでき、超える申請はエラーになる" do
    grant!(2)
    over = build_leave(d(11, 25), d(11, 27)) # 3日
    assert_not over.submit
    assert_includes over.errors.full_messages,
                    "有給休暇の残日数が足りないため申請できません（この申請 3日・休暇の日付に使える残り 2日）。日数を減らすか、特別休暇・欠勤で申請してください"
    assert_not over.persisted?

    exact = build_leave(d(11, 25), d(11, 26))
    assert exact.submit, exact.errors.full_messages.inspect
  end

  test "承認待ちの有給も差し引いて、残日数を超える申請はできない" do
    grant!(3)
    leave!(d(11, 25), d(11, 26)) # 承認待ち 2日
    over = build_leave(d(12, 1), d(12, 2))
    assert_not over.submit
    assert_match "承認待ちの有給 2日 も差し引いて数えています", over.errors.full_messages.first
    assert_match "休暇の日付に使える残り 1日", over.errors.full_messages.first

    assert build_leave(d(12, 1)).submit
  end

  test "特別休暇・欠勤は残日数に関係なく申請でき、残日数も変わらない" do
    approve!(leave!(d(11, 25), d(11, 27), type: "special"))
    leave!(d(12, 1), type: "absence")
    assert_equal 0, account.balance
    assert_equal 0, account.shortage
  end

  test "承認するときにも残日数を確かめ直す（申請の後に他の有給が承認された場合など）" do
    grant!(2)
    first = leave!(d(11, 25), d(11, 26))
    # 申請時の確かめを通り抜けた2件目（データの不整合）を想定して、確かめを飛ばして保存する
    second = build_leave(d(12, 1))
    second.save!(validate: false)

    approve!(first)
    blockers = LeaveRequest.find(second.id).approval_blockers
    assert_equal [ "有給休暇の残日数が足りないため承認できません（この休暇 1日・休暇の日付に使える残り 0日）。有給を付与してから承認するか、却下してください" ], blockers

    review = ApprovalReview.new(approval_request: ApprovalRequest.find(second.id), reviewer: @admin, decision: "approve")
    assert_not review.save
    assert second.reload.pending?
    assert_equal 0, account.balance

    # 却下はできる
    reject = ApprovalReview.new(approval_request: ApprovalRequest.find(second.id), reviewer: @admin, decision: "reject", comment: "残日数が足りないため")
    assert reject.save
  end

  test "有効期限の切れた付与分は残日数から除き、期限の後の休暇には使えない" do
    grant!(3, granted_on: d(11, 25, year: 2024), expires_on: d(11, 30)) # 11/30(月) まで
    assert_equal 3, account.balance
    assert_equal [ d(11, 30), 3 ], account.next_expiry

    # 11/30 までの休暇には使える
    approve!(leave!(d(11, 30)))
    # 12/1 の休暇には使えない（今の残りは2日あるが、休暇の日付には期限が切れている）
    later = build_leave(d(12, 1))
    assert_not later.submit
    assert_includes later.errors.full_messages.join, "休暇の日付より前に有効期限が切れる分"

    travel_to Time.zone.local(2026, 12, 1, 9, 0) do
      assert_equal 0, PaidLeaveAccount.new(@user.reload).balance
      assert_equal 2, PaidLeaveAccount.new(@user).ledger.lapsed_days(@user.paid_leave_grants.first)
    end
  end

  test "古い付与から先に消化する" do
    old = grant!(1, granted_on: d(4, 1, year: 2025))
    newer = grant!(10, granted_on: d(4, 1))
    approve!(leave!(d(11, 25), d(11, 26)))
    ledger = account.ledger
    assert_equal 1, ledger.used_days(ledger.grants.find { |g| g.id == old.id })
    assert_equal 1, ledger.used_days(ledger.grants.find { |g| g.id == newer.id })
    assert_equal 9, account.balance
  end

  test "付与が0件のときに承認済みの有給があれば、残り0日・不足として数え、新しい有給は申請できない。付与を登録すると解消する" do
    leave = build_leave(d(11, 20), d(11, 24))
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)

    assert_equal 0, account.balance
    assert_equal 2, account.shortage
    assert_not build_leave(d(11, 26)).submit

    # 付与日を過去にして付与を登録すると、その時期の有給にも充てて計算し直す
    grant!(10, granted_on: d(4, 1))
    assert_equal 8, account.balance
    assert_equal 0, account.shortage
  end

  test "既に不足がある人でも、新しい付与で賄える有給は申請できる（不足はこの申請のせいにしない）" do
    leave = build_leave(d(11, 20))
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    grant!(1, granted_on: d(11, 24)) # 11/20 には使えない
    assert_equal 1, account.shortage

    assert build_leave(d(11, 25)).submit
  end

  test "当年度（4/1〜翌3/31）の取得日数は、取得予定も含め、取消・承認待ちは数えない" do
    grant!(20, granted_on: d(4, 1))
    approve!(leave!(d(11, 20), d(11, 24))) # 2日（取得済み）
    approve!(leave!(d(12, 1), part: "morning")) # 0.5日（予定）
    cancelled = approve!(leave!(d(12, 2)))
    LeaveDirectCancellation.new(leave_request: cancelled, admin: @admin, reason: "取消").save
    leave!(d(12, 3)) # 承認待ち

    paid = account
    assert_equal d(4, 1)..d(3, 31, year: 2027), paid.fiscal_year_range
    assert_equal 2, paid.fiscal_year_taken_until_today
    assert_equal Rational(1, 2), paid.fiscal_year_scheduled_days
    assert_equal Rational(5, 2), paid.fiscal_year_taken_days
    assert paid.below_annual_target?
  end

  test "当年度の境界（3/31 と 4/1）" do
    assert_equal d(4, 1, year: 2025)..d(3, 31), PaidLeaveAccount.fiscal_year_range(d(3, 31))
    assert_equal d(4, 1)..d(3, 31, year: 2027), PaidLeaveAccount.fiscal_year_range(d(4, 1))
  end

  test "履歴に付与・取得・取消・承認待ちが新しい順に並ぶ" do
    grant!(10, granted_on: d(4, 1))
    approve!(leave!(d(11, 20), d(11, 24)))
    cancelled = approve!(leave!(d(11, 26)))
    LeaveDirectCancellation.new(leave_request: cancelled, admin: @admin, reason: "取消").save
    leave!(d(12, 1))

    kinds = account.history.map(&:kind)
    assert_equal %i[pending cancelled usage grant], kinds
    usage = account.history.find { |entry| entry.kind == :usage }
    assert_equal(-2, usage.days)
  end

  test "誤って登録した付与は削除できるが、承認済み・承認待ちの有給が賄えなくなる場合は削除できない" do
    keep = grant!(1)
    extra = grant!(5)
    leave!(d(11, 25), d(11, 26)) # 承認待ち 2日（keep 1日 + extra 1日）

    removal = PaidLeaveGrantRemoval.new(grant: extra, admin: @admin, reason: "誤登録")
    assert_not removal.save
    assert_match "1日 が付与で賄えなくなるため、削除できません", removal.errors.full_messages.first
    assert_not extra.reload.removed?

    grant!(3)
    assert PaidLeaveGrantRemoval.new(grant: extra, admin: @admin, reason: "誤登録").save
    assert extra.reload.removed?
    assert_not keep.reload.removed?
    assert_not_includes @user.paid_leave_grants.reload, extra
  end
end
