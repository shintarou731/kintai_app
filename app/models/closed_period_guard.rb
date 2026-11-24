# 締め済み（F14）の月度にかかる日付かどうかの判定の入口。
#
# 「締めた月度の勤怠は変更できない」（F14）を、各機能から同じ形で確かめるために使う。
# 今は締め（F14）が未実装なので、締め済みの月度は無い（常に nil を返す）。
# F14 で締めの仕組みを作ったら、このメソッドの中身だけを差し替える。呼び出し側は変えなくてよい。
#
# 呼び出し側
# - LeaveDirectCancellation（管理者による休暇の直接取消）… 締め済みの月度に1日でもかかる休暇は取り消せない。
#   画面（承認画面の詳細）も LeaveRequest#direct_cancellation_blocker 経由でこれを見て、取消の操作を出さない。
module ClosedPeriodGuard
  # from〜to の期間と1日でも重なる締め済みの月度の表示名（例：「2026年11月度」）。重ならなければ nil
  def self.closed_period_label(from, to)
    return nil if from.nil? || to.nil?

    nil
  end
end
