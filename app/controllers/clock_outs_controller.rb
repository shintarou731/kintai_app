# 退勤の打刻（ホーム画面の「退勤」ボタン）
class ClockOutsController < ApplicationController
  def create
    # attendance_id は画面に表示していた勤務。拒否されたときのメッセージを選ぶためだけに使う
    attendance = TimeClock.new(current_user).clock_out!(attendance_id: params[:attendance_id])
    redirect_to root_path, notice: clock_out_message(attendance)
  rescue TimeClock::Error => e
    redirect_to root_path, alert: e.message
  end

  private

  # 例：「退勤しました（18:00）。本日の実働時間は 8:00 です（休憩 1:00）。」
  def clock_out_message(attendance)
    worked = helpers.format_duration(attendance.worked_minutes)
    break_minutes = attendance.break_minutes
    message = "退勤しました（#{helpers.format_clock_time(attendance.clock_out_at)}）。"
    if attendance.work_date == Date.current
      message + "本日の実働時間は #{worked} です" + (break_minutes.positive? ? "（休憩 #{helpers.format_duration(break_minutes)}）。" : "。")
    else
      details = [ "実働 #{worked}", ("休憩 #{helpers.format_duration(break_minutes)}" if break_minutes.positive?) ].compact.join("、")
      message + "#{l(attendance.work_date, format: :short_with_day)} の勤務として記録しました（#{details}）。"
    end
  end
end
