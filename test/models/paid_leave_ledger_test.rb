require "test_helper"

# 有給休暇の残日数の計算（F10）。DB を使わず、付与と休暇のオブジェクトだけで確かめる。
# 2026-11-20 は金曜日、11/23 は勤労感謝の日（月・祝日）。
class PaidLeaveLedgerTest < ActiveSupport::TestCase
  def grant(granted_on, days, expires_on = nil)
    PaidLeaveGrant.new(granted_on: granted_on, half_days: (days * 2).to_i, expires_on: expires_on || granted_on + 2.years)
  end

  def leave(from, to = from, part: "full_day")
    LeaveRequest.new(target_date: from, end_date: to, leave_type: "paid", day_part: part, status: "approved")
  end

  def ledger(grants, leaves, today: Date.new(2026, 11, 25))
    PaidLeaveLedger.new(grants: grants, leaves: leaves, today: today)
  end

  test "全日は1日、半休は0.5日、休日（土日・祝日）は数えずに残日数から引く" do
    g = grant(Date.new(2026, 4, 1), 10)
    # 11/20(金)〜11/24(火)：11/21(土)・11/22(日)・11/23(勤労感謝の日)を除いて2日
    result = ledger([ g ], [ leave(Date.new(2026, 11, 20), Date.new(2026, 11, 24)), leave(Date.new(2026, 11, 26), part: "morning") ])

    assert_equal Rational(15, 2), result.balance
    assert_equal Rational(5, 2), result.used_days(g)
    assert_equal 0, result.shortage
  end

  test "付与が無ければ残日数は0日で、取得した分は不足として数える（マイナスにはしない）" do
    result = ledger([], [ leave(Date.new(2026, 11, 20), Date.new(2026, 11, 24)) ])

    assert_equal 0, result.balance
    assert_equal 2, result.shortage
  end

  test "古い付与から先に消化する。1日分が2つの付与にまたがることもある" do
    old = grant(Date.new(2025, 4, 1), 1.5)
    new_grant = grant(Date.new(2026, 4, 1), 10)
    # 入れる順番を逆にしても、付与日の古い順に消化する
    result = ledger([ new_grant, old ], [ leave(Date.new(2026, 11, 26), Date.new(2026, 11, 27)) ])

    assert_equal Rational(3, 2), result.used_days(old)
    assert_equal Rational(1, 2), result.used_days(new_grant)
    assert_equal Rational(19, 2), result.balance
    usage = result.usage_for(result.leaves.first)
    assert_equal [ old, new_grant ], usage.grants
  end

  test "有効期限の日の休暇には使え、翌日の休暇には使えない" do
    g = grant(Date.new(2024, 12, 1), 5, Date.new(2026, 12, 1)) # 12/1(火) まで
    on_expiry = ledger([ g ], [ leave(Date.new(2026, 12, 1)) ], today: Date.new(2026, 11, 25))
    assert_equal 0, on_expiry.shortage
    assert_equal 4, on_expiry.balance

    after_expiry = ledger([ g ], [ leave(Date.new(2026, 12, 2)) ], today: Date.new(2026, 11, 25))
    assert_equal 1, after_expiry.shortage
    assert_equal 5, after_expiry.balance
  end

  test "付与日より前の休暇には使えない。付与日の休暇には使える" do
    g = grant(Date.new(2026, 11, 20), 5)

    assert_equal 1, ledger([ g ], [ leave(Date.new(2026, 11, 19)) ]).shortage
    assert_equal 0, ledger([ g ], [ leave(Date.new(2026, 11, 20)) ]).shortage
  end

  test "残日数は今日の時点で有効な付与だけを数える（有効期限の日までは残り、翌日に失効する）" do
    g = grant(Date.new(2024, 11, 25), 5, Date.new(2026, 11, 25))
    used = [ leave(Date.new(2026, 11, 20)) ]

    on_last_day = ledger([ g ], used, today: Date.new(2026, 11, 25))
    assert_equal 4, on_last_day.balance
    assert_equal :active, on_last_day.grant_state(g)
    assert_equal 0, on_last_day.lapsed_days(g)

    next_day = ledger([ g ], used, today: Date.new(2026, 11, 26))
    assert_equal 0, next_day.balance
    assert_equal :expired, next_day.grant_state(g)
    assert_equal 4, next_day.lapsed_days(g)
  end

  test "有効期限が切れる付与が残っていても、期限の後の休暇には新しい付与を使う" do
    old = grant(Date.new(2024, 12, 1), 3, Date.new(2026, 11, 30))
    new_grant = grant(Date.new(2025, 12, 1), 10)
    # 12/1(火)・12/2(水)：old は 11/30 で切れるので、new_grant から消化する
    result = ledger([ old, new_grant ], [ leave(Date.new(2026, 12, 1), Date.new(2026, 12, 2)) ])

    assert_equal 0, result.used_days(old)
    assert_equal 2, result.used_days(new_grant)
    assert_equal 11, result.balance
    assert_equal [ Date.new(2026, 11, 30), 3 ], result.next_expiry
  end

  test "休暇の日は日付の早い順に、その日に使える古い付与へ割り当てる" do
    old = grant(Date.new(2025, 1, 1), 1, Date.new(2026, 11, 27))
    new_grant = grant(Date.new(2026, 1, 1), 1)
    # 11/30(月) は old の期限後なので new_grant。11/26(木) は old。並びが逆でも結果は同じ
    result = ledger([ old, new_grant ], [ leave(Date.new(2026, 11, 30)), leave(Date.new(2026, 11, 26)) ])

    assert_equal 0, result.shortage
    assert_equal 1, result.used_days(old)
    assert_equal 1, result.used_days(new_grant)
  end
end
