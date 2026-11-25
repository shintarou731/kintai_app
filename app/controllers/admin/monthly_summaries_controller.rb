# 月次集計（F14）：月度ごとの従業員別の集計と、締めの状態・警告（index）。従業員の日別の勤怠と、直接修正の履歴（show）。
# 月度は勤務ルール（F6）の締め日と、締め済みの月度に従う（AttendanceCalendar）。?month=2026-11 で選ぶ（省略時は今月度）
class Admin::MonthlySummariesController < Admin::BaseController
  INVALID_MONTH_MESSAGE = "指定された月を表示できません。今月の月次集計を表示します。".freeze
  # 月度の一覧に出す月の数（今月度から前へ）
  MONTH_LIST_SIZE = 12

  before_action :set_period

  def index
    @summary = MonthlySummary.new(period: @period, rules: @rules, now: @now)
    @month_list = Array.new(MONTH_LIST_SIZE) { |index| @current_period.first_of_month << index }
                       .map { |date| @rules.calendar.period(date.year, date.month) }
    @closing_history = MonthlyClosing.recent_first.includes(:closed_by, :reopened_by).limit(10).to_a
  end

  def show
    @user = User.find_by(id: params[:id])
    return redirect_to admin_monthly_summaries_path(month: @period.to_param), alert: "指定された従業員が見つかりません。" if @user.nil?

    @monthly = MonthlyAttendance.for_user(@user, period: @period, rules: @rules, now: @now)
    @edits = AttendanceEdit.where(user: @user, work_date: @period.date_range).includes(:editor).recent_first.to_a
    @edited_dates = @edits.map(&:work_date).tally
    @active_admin_count = User.active_admins.count
  end

  private

  def set_period
    @rules = WorkRules.current
    @now = Time.current
    @current_period = @rules.period_containing(@now.to_date)
    if params[:month].present?
      @period = @rules.period_from_param(params[:month])
      redirect_to admin_monthly_summaries_path, alert: INVALID_MONTH_MESSAGE if @period.nil?
    else
      @period = @current_period
    end
  end
end
