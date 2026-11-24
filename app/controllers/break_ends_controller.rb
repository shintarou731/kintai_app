# 休憩終了の打刻（ホーム画面の「休憩終了」ボタン）
class BreakEndsController < ApplicationController
  def create
    attendance_break = TimeClock.new(current_user).end_break!
    redirect_to root_path, notice: break_end_message(attendance_break)
  rescue TimeClock::Error => e
    redirect_to root_path, alert: e.message
  end

  private

  def break_end_message(attendance_break)
    total = attendance_break.attendance.reload.break_minutes
    "休憩を終了しました（#{helpers.format_clock_time(attendance_break.ended_at)}）。" \
      "今回の休憩は #{helpers.format_duration(attendance_break.duration_minutes)}、休憩の合計は #{helpers.format_duration(total)} です。"
  end
end
