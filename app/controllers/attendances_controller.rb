# 自分の勤怠履歴（月次）：選んだ月の1日〜末日の勤怠と、その月の合計を表示する
class AttendancesController < ApplicationController
  def index
    rules = WorkRules.current
    now = Time.current

    if params[:month].present?
      period = rules.period_from_param(params[:month])
      return redirect_to attendances_path, alert: "指定された月を表示できません。今月の勤怠履歴を表示します。" unless period
    else
      period = rules.period_containing(now.to_date)
    end

    @monthly = MonthlyAttendance.new(current_user, period: period, rules: rules, now: now)
    @current_period = rules.period_containing(now.to_date)
  end
end
