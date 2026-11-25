# 締め済み（F14）の月度にかかる日付かどうかの判定の入口。
#
# 「締めた月度の勤怠は変更できない」（F14）を、勤怠を書き換えるすべての入口で、同じ形で確かめるために使う。
# 判定は毎回 DB の締めの記録（MonthlyClosing.active）を読む。各入口は、書き込みのトランザクションの中でこれを呼ぶ
# （SQLite は BEGIN IMMEDIATE で書き込みが1つずつになるので、締めと同時に届いても、判定と書き込みの間に締めが割り込まない）。
#
# 呼び出し側（勤怠を書き換える入口）
# - TimeClock（出勤・退勤・休憩の打刻）… 勤務日が締め済みの月度に入る勤務には打刻できない
# - AttendanceCorrectionRequest（打刻修正申請）… 申請（作成時のバリデーション）と承認（approval_blockers）
# - LeaveRequest（休暇申請）… 申請（作成時のバリデーション）と承認（approval_blockers）。
#   管理者の直接取消（LeaveDirectCancellation）も LeaveRequest#direct_cancellation_blockers 経由で使う
# - LeaveCancellationRequest（休暇の取消申請）… 申請と承認
# - AttendanceRecordEditor（管理者による勤怠の直接修正・削除）
# 却下・取り下げは勤怠を変えないので止めない（承認待ちのまま締めた申請は、却下か取り下げで片付ける）。
module ClosedPeriodGuard
  # from〜to の期間と1日でも重なる締め済みの月度（MonthlyClosing）。重ならなければ nil
  def self.closing_overlapping(from, to = from)
    return nil if from.nil? || to.nil?

    MonthlyClosing.active.overlapping(from, to).order(:start_date).first
  end

  # from〜to の期間と1日でも重なる締め済みの月度の表示名（例：「2026年11月度」）。重ならなければ nil
  def self.closed_period_label(from, to = from)
    closing_overlapping(from, to)&.label
  end

  # date が締め済みの月度に入るか
  def self.closed?(date)
    !closing_overlapping(date).nil?
  end

  # 画面に出す説明（例：「締め済みの月度（2026年11月度：10/21(水)〜11/20(金)）」）
  def self.describe(closing)
    "締め済みの月度（#{closing.label}：#{closing.range_label}）"
  end
end
