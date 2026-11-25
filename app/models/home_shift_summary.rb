# ホーム画面（F12）に出す、自分の今日と次回のシフト。公開済みの内容（published_*）だけを使う。
#
# - 今日のシフト：勤務日（シフトの日）が今日のシフト。
# - 前日から続くシフト：前日に始まって日付をまたぐシフトで、まだ終わっていないもの（例：0:30 に見たときの 22:00〜翌6:00）。
# - 次回のシフト：明日以降で、いちばん近いシフト。
# - 今日の予実（ShiftCheck）：遅刻・未出勤などを、今日のシフトの横に出す。
class HomeShiftSummary
  attr_reader :user, :now

  def initialize(user, now: Time.current)
    @user = user
    @now = now.in_time_zone
  end

  def today
    now.to_date
  end

  def today_shift
    return @today_shift if defined?(@today_shift)

    @today_shift = published.find_by(work_date: today)
  end

  def ongoing_previous_shift
    return @ongoing_previous_shift if defined?(@ongoing_previous_shift)

    shift = published.find_by(work_date: today - 1)
    @ongoing_previous_shift = shift && shift.published_ends_at > now ? shift : nil
  end

  def next_shift
    return @next_shift if defined?(@next_shift)

    @next_shift = published.where(work_date: (today + 1)..).order(:work_date).first
  end

  def today_check
    @today_check ||= ShiftCheck.new(shift: today_shift, attendance: user.attendances.find_by(work_date: today),
                                    leaves: Shift.effective_leaves_on(user.id, today), now: now)
  end

  # 今日の休暇（承認済み）
  def today_leaves
    today_check.leaves
  end

  private

  def published
    user.shifts.published
  end
end
