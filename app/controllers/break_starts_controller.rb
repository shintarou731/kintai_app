# 休憩開始の打刻（ホーム画面の「休憩開始」ボタン）
class BreakStartsController < ApplicationController
  def create
    attendance_break = TimeClock.new(current_user).start_break!
    redirect_to root_path, notice: "休憩を開始しました（#{helpers.format_clock_time(attendance_break.started_at)}）"
  rescue TimeClock::Error => e
    redirect_to root_path, alert: e.message
  end
end
