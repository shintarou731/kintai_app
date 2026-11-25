# 前日以前の退勤漏れ（F13）：退勤の打刻が無いまま、勤務日（出勤した日）が過ぎた勤務の一覧。
#
# 数え方は勤怠履歴（F5）の「退勤漏れ」と同じ（Attendance#missing_clock_out?：勤務日が今日より前で、退勤が無い）。
# - 日付をまたいで勤務中で、まだ本人がホーム画面から退勤できる勤務（出勤から24時間以内）も含める（Item#clock_out_open?）。
#   退勤すれば一覧から消える。
# - 無効な従業員の勤務も含める（月の締めの前に、記録を直す必要があるため）。
# ダッシュボードの件数と、この一覧の件数は必ず一致する。
class MissingClockOutList
  Item = Data.define(:attendance, :pending_correction, :now) do
    delegate :user, :work_date, :clock_in_at, to: :attendance

    # まだ本人がホーム画面から退勤できる（出勤から24時間以内）
    def clock_out_open?
      attendance.clock_out_open?(as_of: now)
    end
  end

  attr_reader :now

  def initialize(now: Time.current)
    @now = now.in_time_zone
  end

  def today
    now.to_date
  end

  # 勤務日の新しい順
  def items
    @items ||= begin
      attendances = Attendance.without_clock_out.where(work_date: ...today).includes(:user)
                              .order(work_date: :desc, user_id: :asc).to_a
      corrections = AttendanceCorrectionRequest.pending.where(user_id: attendances.map(&:user_id).uniq,
                                                              target_date: attendances.map(&:work_date).uniq)
                                               .index_by { |request| [ request.user_id, request.target_date ] }
      attendances.map do |attendance|
        Item.new(attendance: attendance, pending_correction: corrections[[ attendance.user_id, attendance.work_date ]], now: now)
      end
    end
  end

  def count
    items.size
  end

  def any?
    items.any?
  end

  # まだ本人が退勤できる勤務の件数
  def open_count
    items.count(&:clock_out_open?)
  end

  # 修正申請が出ている（承認待ちの）件数
  def pending_correction_count
    items.count(&:pending_correction)
  end
end
