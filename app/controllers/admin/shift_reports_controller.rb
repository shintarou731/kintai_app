# 予実の確認（F12）：月度ごとの従業員別の遅刻・早退・欠勤の回数（index）と、1人の日ごとの予定（シフト）と実績（打刻）（show）。
# 月度は勤務ルール（F6）の締め日に従う。?month=2026-11 で選ぶ（省略時は今月度）
class Admin::ShiftReportsController < Admin::BaseController
  INVALID_MONTH_MESSAGE = "指定された月を表示できません。今月の予実を表示します。".freeze

  before_action :set_period

  def index
    @report = ShiftReport.new(period: @period, rules: @rules, now: @now)
  end

  def show
    @user = User.find_by(id: params[:id])
    return redirect_to admin_shift_reports_path(month: @period.to_param), alert: "指定された従業員が見つかりません。" if @user.nil?

    @monthly = MonthlyAttendance.for_user(@user, period: @period, rules: @rules, now: @now)
  end

  private

  def set_period
    @rules = WorkRules.current
    @now = Time.current
    @current_period = @rules.period_containing(@now.to_date)
    if params[:month].present?
      @period = @rules.period_from_param(params[:month])
      redirect_to admin_shift_reports_path, alert: INVALID_MONTH_MESSAGE if @period.nil?
    else
      @period = @current_period
    end
  end
end
