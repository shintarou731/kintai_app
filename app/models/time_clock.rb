# ある従業員の「今」の打刻状態と、出勤・退勤・休憩の打刻を扱う。
#
# 状態（state）
# - :not_started … 今日まだ出勤していない（出勤ボタンだけ押せる）
# - :working     … 出勤して退勤していない（退勤・休憩開始が押せる）。日付をまたいだ勤務も含む
# - :on_break    … 勤務中で休憩している（休憩終了だけ押せる。退勤はできない）
# - :finished    … 今日の勤務は退勤済み（同じ日に2回目の出勤はできない）
class TimeClock
  # 出勤からこの時間を過ぎても退勤の打刻が無い勤務は、ホーム画面から退勤できなくなり、
  # 現在の勤務としては扱わない（翌日以降の出勤を妨げないため）。
  # なお勤怠履歴では、この期限に関係なく、勤務日が過ぎた時点で「退勤漏れ」と表示する（Attendance#missing_clock_out?）
  # 期限は出勤時刻の秒を切り捨てて数える（画面に出す「10:00 まで」と判定をそろえるため）。
  MAX_SHIFT_DURATION = 24.hours

  class Error < StandardError; end

  # 同時に届いた別の打刻と競合したとき（内部用）
  class Conflict < StandardError; end
  private_constant :Conflict

  attr_reader :user, :now

  # 出勤時刻 clock_in_at の勤務を、ホーム画面から退勤できる期限
  def self.clock_out_deadline_for(clock_in_at)
    clock_in_at.change(sec: 0) + MAX_SHIFT_DURATION
  end

  # 時刻 now の時点でまだ退勤できる勤務の、最も早い出勤時刻。
  # 「秒を切り捨てた出勤時刻 + 24時間 >= now」は「出勤時刻 >= (now − 24時間) を分単位に切り上げた時刻」と同じ
  def self.earliest_open_clock_in(now)
    threshold = now - MAX_SHIFT_DURATION
    floored = threshold.change(sec: 0)
    floored == threshold ? floored : floored + 1.minute
  end

  def initialize(user, now: Time.current)
    @user = user
    @now = now.in_time_zone
  end

  def today
    now.to_date
  end

  # 退勤していない勤務（退勤できる期限内）。前日に出勤した勤務のこともある
  def current_attendance
    return @current_attendance if defined?(@current_attendance)

    @current_attendance = user.attendances.without_clock_out
                              .where(clock_in_at: self.class.earliest_open_clock_in(now)..now)
                              .includes(:breaks)
                              .order(clock_in_at: :desc).first
  end

  # 今日を勤務日とする勤務
  def today_attendance
    return @today_attendance if defined?(@today_attendance)

    @today_attendance = user.attendances.includes(:breaks).find_by(work_date: today)
  end

  # ホーム画面に表示する勤務（勤務中の勤務を優先し、無ければ今日の勤務）
  def attendance
    current_attendance || today_attendance
  end

  def state
    if current_attendance
      current_attendance.on_break? ? :on_break : :working
    elsif today_attendance then :finished
    else :not_started
    end
  end

  def can_clock_in?
    state == :not_started
  end

  # 休憩中は退勤できない（先に休憩を終える）
  def can_clock_out?
    state == :working
  end

  def can_start_break?
    state == :working
  end

  def can_end_break?
    state == :on_break
  end

  # 今日の勤務が無いときに参考として出す、直前（前日）の勤務。夜勤明けの確認用
  def previous_attendance
    return if attendance

    user.attendances.includes(:breaks).where(work_date: today.yesterday).where.not(clock_out_at: nil).first
  end

  # 退勤の打刻が無いまま MAX_SHIFT_DURATION を過ぎ、ホーム画面からは退勤できなくなった勤務（新しい順）
  def missing_clock_outs
    user.attendances.without_clock_out.where(clock_in_at: ...self.class.earliest_open_clock_in(now)).order(work_date: :desc)
  end

  # 出勤を打刻し、作成した勤怠を返す。打刻できない状態なら TimeClock::Error
  def clock_in!
    ensure_can_clock_in!
    user.attendances.create!(work_date: today, clock_in_at: now)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # ほぼ同時に届いた2回目の出勤（二重クリックなど）。1件目だけが記録されている
    reset_cache
    ensure_can_clock_in!
    raise Error, "出勤を記録できませんでした。画面を再読み込みしてください。"
  end

  # 退勤を打刻し、更新した勤怠を返す。打刻できない状態なら TimeClock::Error
  #
  # attendance_id … 画面に表示していた勤務の ID（任意）。打刻が拒否されたときに
  #                 「その勤務はすでに退勤済み」なのかを判断してメッセージを選ぶためだけに使う。
  def clock_out!(attendance_id: nil)
    attendance = current_attendance
    raise Error, cannot_clock_out_message(attendance_id) if attendance.nil? || attendance.on_break?

    # 「まだ退勤していない」かつ「休憩中でない」ことを条件に1回の UPDATE で書き込む。
    # 二重クリックで2回届いても、書き込まれるのは最初の1回だけ。休憩開始と同時に届いても休憩中には退勤しない。
    updated = Attendance.where(id: attendance.id, clock_out_at: nil)
                        .where.not(id: AttendanceBreak.ongoing.select(:attendance_id))
                        .update_all(clock_out_at: now, updated_at: now)
    if updated.zero?
      reset_cache
      raise Error, cannot_clock_out_message(attendance_id)
    end

    attendance.reload
  end

  # 休憩開始を打刻し、作成した休憩を返す。打刻できない状態なら TimeClock::Error
  def start_break!
    ensure_can_start_break!
    attendance = current_attendance

    Attendance.transaction(requires_new: true) do
      attendance_break = attendance.breaks.create!(started_at: now)
      # 退勤と同時に届いた場合に備え、まだ退勤していないことを書き込みで確かめる（退勤済みなら取り消す）
      raise Conflict if Attendance.where(id: attendance.id, clock_out_at: nil).update_all(updated_at: now).zero?

      attendance_break
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid, Conflict
    # ほぼ同時に届いた2回目の休憩開始（DB の一意制約で1件だけ）や、退勤との競合
    reset_cache
    ensure_can_start_break!
    raise Error, "休憩開始を記録できませんでした。画面を再読み込みしてください。"
  end

  # 休憩終了を打刻し、更新した休憩を返す。打刻できない状態なら TimeClock::Error
  def end_break!
    attendance_break = current_attendance&.open_break
    raise Error, cannot_end_break_message unless attendance_break

    # 「まだ終わっていない」ことを条件に1回の UPDATE で書き込む（二重クリックでも最初の1回だけ）
    updated = AttendanceBreak.where(id: attendance_break.id, ended_at: nil).update_all(ended_at: now, updated_at: now)
    if updated.zero?
      reset_cache
      raise Error, cannot_end_break_message
    end

    attendance_break.reload
  end

  private

  def ensure_can_clock_in!
    case state
    when :working, :on_break
      raise Error, "すでに出勤しています（#{format_time(current_attendance.clock_in_at)} に出勤）。退勤してから出勤してください。"
    when :finished
      raise Error, "本日はすでに退勤済みのため、出勤できません（同じ日に出勤できるのは1回です）。"
    end
  end

  def ensure_can_start_break!
    case state
    when :not_started
      raise Error, "出勤していないため、休憩を開始できません。先に出勤を打刻してください。"
    when :finished
      raise Error, "本日の勤務は退勤済みのため、休憩を開始できません。"
    when :on_break
      raise Error, "すでに休憩中です（#{format_time(current_attendance.open_break.started_at)} から）。休憩を終えたら「休憩終了」を押してください。"
    end
  end

  def cannot_clock_out_message(attendance_id)
    return "休憩中のため、退勤できません。先に「休憩終了」を押してください。" if state == :on_break
    return "退勤を記録できませんでした。画面を再読み込みしてください。" if state == :working

    finished = clocked_out_attendance(attendance_id)
    if finished
      "すでに退勤しています（#{format_time(finished.clock_out_at)} に退勤）。"
    else
      "出勤していないため、退勤できません。先に出勤を打刻してください。"
    end
  end

  # 「すでに退勤済み」と案内すべき勤務：画面に表示していた勤務（日付をまたいだ勤務のこともある）か、今日の勤務
  def clocked_out_attendance(attendance_id)
    shown = user.attendances.find_by(id: attendance_id) if attendance_id.present?
    [ shown, today_attendance ].compact.find(&:clocked_out?)
  end

  def cannot_end_break_message
    case state
    when :working
      last_break = current_attendance.finished_breaks.max_by(&:ended_at)
      if last_break
        "すでに休憩を終了しています（#{format_time(last_break.ended_at)} に終了）。"
      else
        "休憩中ではないため、休憩を終了できません。"
      end
    when :finished
      "本日の勤務は退勤済みのため、休憩を終了できません。"
    when :not_started
      "出勤していないため、休憩を終了できません。"
    else
      "休憩終了を記録できませんでした。画面を再読み込みしてください。"
    end
  end

  def reset_cache
    remove_instance_variable(:@current_attendance) if defined?(@current_attendance)
    remove_instance_variable(:@today_attendance) if defined?(@today_attendance)
  end

  def format_time(time)
    I18n.l(time.in_time_zone, format: :time)
  end
end
