# 締め済み（F14）の月度の、ある従業員の勤怠表。締めた時点の値（MonthlyClosingEntry）から作る。
#
# MonthlyAttendance と同じ使い方ができる（勤怠履歴・月次集計の日別の勤怠・予実の確認・CSV（F15）が同じ画面・同じ計算で読める）。
# - 期間：締めた時点の期間（締め日を変えても変わらない）
# - 勤務ルール（#rules）：締めた時点の所定労働時間・警告ラインなど
# - 日別の値（実働・休憩・残業・深夜・休日の勤務・状態）：締めた時点に保存した値をそのまま使う（今の勤務ルールで計算し直さない）
# - 打刻・シフト・休暇も、締めた時点の内容から作る（保存しない Attendance・Shift・LeaveRequest）。
#   遅刻・早退・欠勤の印は、その内容と締めた時刻で ShiftCheck を作って出す（保存した印と同じになる）。
# - 承認待ちの修正申請（「申請中」の印）だけは今の状態を読む。締め済みの月度の申請は承認できないが、却下・取り下げはできるため
#
# 締めた時点に表に入っていなかった従業員（その月度に記録が無かった人）は entry が nil で、空の勤怠表になる。
class ClosedMonthlyAttendance < MonthlyAttendance
  attr_reader :entry

  def self.for_users(users, period:, now: Time.current)
    users = users.to_a
    ids = users.map(&:id)
    entries = period.closing.entries.where(user_id: ids).index_by(&:user_id)
    corrections = AttendanceCorrectionRequest.pending.where(user_id: ids, target_date: period.date_range).group_by(&:user_id)
    users.to_h do |user|
      [ user.id, new(user, period: period, entry: entries[user.id], now: now, corrections: corrections.fetch(user.id, [])) ]
    end
  end

  def initialize(user, period:, entry:, now: Time.current, corrections: nil)
    raise ArgumentError, "締め済みの月度ではありません" unless period.closed?

    super(user, period: period, rules: period.closing.rules, now: now)
    @entry = entry
    @corrections = corrections
  end

  def closed?
    true
  end

  def closing
    period.closing
  end

  def days
    @days ||= period.dates.map { |date| frozen_day(date, snapshot_days[date]) }
  end

  private

  def snapshot
    @snapshot ||= entry&.snapshot || {}
  end

  def snapshot_days
    @snapshot_days ||= Array(snapshot["days"]).index_by { |data| Date.iso8601(data["date"]) }
  end

  # 締めた時点に有効だった（承認済みで取り消されていない）休暇
  def leaves
    @leaves ||= Array(snapshot["leaves"]).map do |data|
      LeaveRequest.new(id: data["id"], user_id: user.id, status: "approved", leave_type: data["leave_type"], day_part: data["day_part"],
                       target_date: Date.iso8601(data["target_date"]), end_date: Date.iso8601(data["end_date"]))
    end
  end

  def pending_corrections_by_date
    @pending_corrections_by_date ||= (@corrections || user.attendance_correction_requests.pending.where(target_date: period.date_range).to_a)
                                     .index_by(&:target_date)
  end

  def frozen_day(date, data)
    attendance = data && data["attendance"] && frozen_attendance(date, data["attendance"])
    shift = data && data["shift"] && frozen_shift(date, data["shift"])
    check = ShiftCheck.new(shift: shift, attendance: attendance, leaves: leaves_on(date).select(&:effective?), now: closing.closed_at)
    return Day.new(date: date, attendance: nil, status: :none, worked_minutes: 0, break_minutes: 0, overtime_minutes: 0,
                   night_minutes: 0, clock_out_open: false, shift_check: check) if attendance.nil?

    Day.new(date: date, attendance: attendance, status: data["status"].to_sym, worked_minutes: data["worked"],
            break_minutes: data["break"], overtime_minutes: data["overtime"], night_minutes: data["night"],
            clock_out_open: false, shift_check: check)
  end

  def frozen_attendance(date, data)
    parse = ->(value) { value.presence && Time.zone.iso8601(value) }
    Attendance.new(user_id: user.id, work_date: date, clock_in_at: parse.call(data["clock_in_at"]),
                   clock_out_at: parse.call(data["clock_out_at"])).tap do |attendance|
      Array(data["breaks"]).each do |started_at, ended_at|
        attendance.breaks.build(started_at: parse.call(started_at), ended_at: parse.call(ended_at))
      end
    end
  end

  def frozen_shift(date, data)
    parse = ->(value) { value.presence && Time.zone.iso8601(value) }
    Shift.new(user_id: user.id, work_date: date, start_minute: data["start"], end_minute: data["end"], break_minutes: data["break"],
              published_start_minute: data["start"], published_end_minute: data["end"], published_break_minutes: data["break"],
              published_at: parse.call(data["published_at"]), revised_at: parse.call(data["revised_at"]))
  end
end
