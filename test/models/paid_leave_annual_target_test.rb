require "test_helper"

# 年5日未満の印（F10・スプリント 16.1）：当年度（2026/04/01〜2027/03/31）と使える期間が重なる付与がある人だけに付ける。
# 今日は 2026-11-26(木) に固定する。
class PaidLeaveAnnualTargetTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 26, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @user = User.create!(name: "年度 確認", email: "annual-target@example.com", password: "password123", hired_on: Date.new(2022, 4, 1))
  end

  teardown { travel_back }

  def grant!(days, granted_on:, expires_on:, user: @user)
    PaidLeaveGrant.create!(user: user, granted_by: @admin, granted_on: granted_on, days: days.to_s, expires_on: expires_on)
  end

  def approved_leave!(from, to = from, user: @user)
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: "paid", day_part: "full_day", reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  def account(user = @user)
    PaidLeaveAccount.new(User.find(user.id))
  end

  test "当年度は 2026/04/01〜2027/03/31" do
    assert_equal Date.new(2026, 4, 1)..Date.new(2027, 3, 31), account.fiscal_year_range
  end

  test "付与が1件も無い人には、当年度の取得が0日でも印を付けない" do
    assert_equal 0, account.fiscal_year_taken_days
    assert account.below_annual_target?
    assert_not account.fiscal_year_grants?
    assert_not account.annual_target_alert?
  end

  test "当年度より前に有効期限が切れた付与（2024/03/01〜2026/02/28）だけの人には、印を付けない" do
    grant!(10, granted_on: Date.new(2024, 3, 1), expires_on: Date.new(2026, 2, 28))
    assert_not account.fiscal_year_grants?
    assert_not account.annual_target_alert?
  end

  test "年度の後半（2026/10/01）に10日付与され、当年度の取得が2日の人には印を付ける" do
    grant!(10, granted_on: Date.new(2026, 10, 1), expires_on: Date.new(2028, 10, 1))
    approved_leave!(Date.new(2026, 11, 19), Date.new(2026, 11, 20)) # 木・金の2日
    assert_equal 2, account.fiscal_year_taken_days
    assert account.annual_target_alert?
  end

  test "当年度中に有効期限が切れた付与（〜2026/06/30）だけの人も「付与がある」として扱い、5日未満なら印を付ける" do
    grant!(10, granted_on: Date.new(2024, 7, 1), expires_on: Date.new(2026, 6, 30))
    assert account.fiscal_year_grants?
    assert account.annual_target_alert?
  end

  test "当年度の取得が5日以上なら、付与があっても印を付けない" do
    grant!(10, granted_on: Date.new(2026, 4, 1), expires_on: Date.new(2028, 4, 1))
    approved_leave!(Date.new(2026, 11, 16), Date.new(2026, 11, 20)) # 月〜金の5日
    assert_equal 5, account.fiscal_year_taken_days
    assert_not account.annual_target_alert?
  end

  test "境目：有効期限が年度の初日（2026/04/01）なら重なり、前日（2026/03/31）なら重ならない" do
    grant = grant!(1, granted_on: Date.new(2025, 4, 1), expires_on: Date.new(2026, 3, 31))
    assert_not account.annual_target_alert?

    grant.update_columns(expires_on: Date.new(2026, 4, 1))
    assert account.annual_target_alert?
  end

  test "削除した付与は数えない（削除した付与しか無い人には印を付けない）" do
    grant = grant!(10, granted_on: Date.new(2026, 10, 1), expires_on: Date.new(2028, 10, 1))
    assert account.annual_target_alert?

    assert PaidLeaveGrantRemoval.new(grant: grant, admin: @admin, reason: "誤登録").save
    assert_not account.fiscal_year_grants?
    assert_not account.annual_target_alert?
    assert_not PaidLeaveAccount.for_users([ @user ]).fetch(@user.id).annual_target_alert?
  end

  test "役割（管理者）にかかわらず同じ基準で判定する" do
    @user.update!(role: "admin")
    assert_not account.annual_target_alert?
    grant!(10, granted_on: Date.new(2026, 10, 1), expires_on: Date.new(2028, 10, 1))
    assert account.annual_target_alert?
  end
end
