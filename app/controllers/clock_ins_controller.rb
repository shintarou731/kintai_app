# 出勤の打刻（ホーム画面の「出勤」ボタン）
class ClockInsController < ApplicationController
  def create
    attendance = TimeClock.new(current_user).clock_in!
    redirect_to root_path, notice: "出勤しました（#{helpers.format_clock_time(attendance.clock_in_at)}）"
  rescue TimeClock::Error => e
    redirect_to root_path, alert: e.message
  end
end
