require "test_helper"

# 有給休暇の付与の削除（F10・スプリント 16.1）：理由が必須・削除の記録・残日数に数えない・削除できない場合は記録を作らない。
# 今日は 2026-11-26(木) に固定する。
class PaidLeaveGrantRemovalTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 26, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @user = User.create!(name: "削除 確認", email: "grant-removal@example.com", password: "password123", hired_on: Date.new(2024, 4, 1))
  end

  teardown { travel_back }

  def grant!(days, granted_on: Date.new(2026, 4, 1), expires_on: nil)
    PaidLeaveGrant.create!(user: @user, granted_by: @admin, granted_on: granted_on, days: days.to_s, expires_on: expires_on)
  end

  def leave!(from, to = from, status: "approved")
    leave = @user.leave_requests.new(target_date: from, end_date: to, leave_type: "paid", day_part: "full_day", reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: status, reviewer_id: (@admin.id if status == "approved"), reviewed_at: (NOW if status == "approved"))
    leave
  end

  def remove(grant, reason: "日数を誤って登録したため", admin: @admin)
    PaidLeaveGrantRemoval.new(grant: grant, admin: admin, reason: reason)
  end

  def account
    PaidLeaveAccount.new(User.find(@user.id))
  end

  test "理由が空（空白だけを含む）なら削除できず、付与はそのまま残り、記録も作られない" do
    grant = grant!(10)
    [ nil, "", "   ", "\n" ].each do |reason|
      removal = remove(grant, reason: reason)
      assert_not removal.save
      assert_equal [ "削除の理由を入力してください" ], removal.errors.full_messages
    end
    grant.reload
    assert_not grant.removed?
    assert_nil grant.removed_by_id
    assert_nil grant.removal_reason
    assert_equal 10, account.balance
  end

  test "削除すると、削除した管理者・日時・理由が記録され、付与の内容（付与日・日数・有効期限）はそのまま残る" do
    grant = grant!(7.5, granted_on: Date.new(2026, 10, 1), expires_on: Date.new(2028, 9, 30))
    assert remove(grant, reason: "  別の従業員と取り違えたため  ").save

    grant.reload
    assert grant.removed?
    assert_equal NOW, grant.removed_at
    assert_equal @admin, grant.removed_by
    assert_equal "別の従業員と取り違えたため", grant.removal_reason
    assert_equal [ Date.new(2026, 10, 1), 15, Date.new(2028, 9, 30) ], [ grant.granted_on, grant.half_days, grant.expires_on ]
    assert_equal [ grant ], @user.removed_paid_leave_grants.to_a
    assert_empty @user.paid_leave_grants.reload
  end

  test "削除した付与は残日数・申請できる残りに数えない（残り 10日 → 0日）" do
    grant = grant!(10)
    assert_equal 10, account.balance
    assert_equal 10, account.requestable

    assert remove(grant).save
    assert_equal 0, account.balance
    assert_equal 0, account.requestable
    assert_not account.any_grants?
    # 一覧用のまとめた読み込みでも数えない
    assert_equal 0, PaidLeaveAccount.for_users([ @user ]).fetch(@user.id).balance
  end

  test "削除した付与は、有給の申請でも承認でも使えない" do
    grant = grant!(2)
    pending = leave!(Date.new(2026, 12, 1), status: "pending")
    keep = grant!(1)
    # 承認待ち1日は keep でも賄えるので、grant は削除できる
    assert remove(grant).save

    leave = @user.leave_requests.new(target_date: Date.new(2026, 12, 2), end_date: Date.new(2026, 12, 3), leave_type: "paid",
                                     day_part: "full_day", reason: "私用")
    assert_not leave.submit
    assert_match "有給休暇の残日数が足りないため申請できません", leave.errors.full_messages.first

    assert_empty LeaveRequest.find(pending.id).approval_blockers
    keep.update_columns(half_days: 1)
    assert_match "残日数が足りないため承認できません", LeaveRequest.find(pending.id).approval_blockers.first
  end

  test "削除すると承認済み・承認待ちの有給が賄えなくなる場合は削除できず、理由が出て、記録は作られない" do
    approved_grant = grant!(2)
    leave!(Date.new(2026, 11, 20)) # 承認済み 1日
    removal = remove(approved_grant)
    assert_not removal.save
    assert_match "承認済み・承認待ちの有給休暇のうち 1日 が付与で賄えなくなるため、削除できません", removal.errors.full_messages.first
    assert_not approved_grant.reload.removed?
    assert_nil approved_grant.removal_reason

    pending_grant = grant!(3, granted_on: Date.new(2026, 11, 1))
    leave!(Date.new(2026, 12, 1), Date.new(2026, 12, 3), status: "pending") # 承認待ち 3日（approved_grant の残り1日 + pending_grant 2日）
    removal = remove(pending_grant)
    assert_not removal.save
    assert_match "2日 が付与で賄えなくなる", removal.errors.full_messages.first
    assert_not pending_grant.reload.removed?
    assert_equal 0, PaidLeaveGrant.removed.where(user: @user).count
  end

  test "同じ付与を二度削除しても、記録は最初の1件のまま変わらない" do
    grant = grant!(5)
    assert remove(grant, reason: "1回目").save
    first_removed_at = grant.reload.removed_at

    travel 1.hour
    second = remove(PaidLeaveGrant.find(grant.id), reason: "2回目", admin: users(:admin))
    assert_not second.save
    assert_match "この付与はすでに削除されています", second.errors.full_messages.first
    grant.reload
    assert_equal "1回目", grant.removal_reason
    assert_equal first_removed_at, grant.removed_at
  end

  test "管理者でないユーザーとしては削除できない" do
    grant = grant!(5)
    removal = remove(grant, admin: users(:employee))
    assert_not removal.save
    assert_match "管理者の権限が無い", removal.errors.full_messages.first
    assert_not grant.reload.removed?
  end

  test "履歴に「付与の削除」が、削除した日・削除した付与の日数で出る。削除した付与の「付与」の行は出ない" do
    kept = grant!(10)
    removed = grant!(3, granted_on: Date.new(2026, 10, 1))
    assert remove(removed, reason: "重複して登録したため").save

    history = account.history
    assert_equal %i[removal grant], history.map(&:kind)
    entry = history.first
    assert_equal Date.new(2026, 11, 26), entry.date
    assert_equal 3, entry.days
    assert_equal removed.id, entry.record.id
    assert_equal "重複して登録したため", entry.record.removal_reason
    assert_equal kept.id, history.last.record.id
  end

  test "台帳は、削除した付与が渡されても数えない" do
    grant = grant!(4)
    grant.mark_removed!(by: @admin, reason: "誤登録")
    ledger = PaidLeaveLedger.new(grants: [ grant ], leaves: [], today: Date.current)
    assert_equal 0, ledger.balance
    assert_empty ledger.grants
  end

  test "DB の制約：削除の日時と理由は必ず一緒に入る" do
    grant = grant!(1)
    assert_raises(ActiveRecord::StatementInvalid) { grant.update_columns(removed_at: Time.current) }
    assert_raises(ActiveRecord::StatementInvalid) { grant.update_columns(removal_reason: "理由だけ") }
    assert_raises(ArgumentError) { grant.mark_removed!(by: @admin, reason: " ") }
  end
end
