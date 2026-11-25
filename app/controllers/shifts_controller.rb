# 自分のシフト（F12）：公開済みのシフトを、月のカレンダーで見る。?month=2026-11 で月を選ぶ（省略時は今月）
class ShiftsController < ApplicationController
  def index
    now = Time.current
    if params[:month].present?
      month = ShiftCalendar.parse_month(params[:month])
      return redirect_to shifts_path, alert: "指定された月を表示できません。今月のシフトを表示します。" unless month
    else
      month = now.to_date.beginning_of_month
    end

    @calendar = ShiftCalendar.new(current_user, month: month, now: now)
    @summary = HomeShiftSummary.new(current_user, now: now)
  end
end
