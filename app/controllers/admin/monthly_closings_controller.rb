# 月度の締め（POST）と解除（DELETE）（F14）。月次集計の画面のボタンから、month=2026-11 を付けて送る
class Admin::MonthlyClosingsController < Admin::BaseController
  before_action :set_month

  # 締めの画面は無いので、URL を直接開いたときは月次集計へ戻す
  def show
    redirect_to admin_monthly_summaries_path(month: month_param), status: :see_other
  end

  def create
    closing = MonthlyClosing.close!(year: @year, month: @month, by: current_user)
    redirect_to admin_monthly_summaries_path(month: month_param), status: :see_other,
                notice: "#{closing.label}（#{closing.range_label}）を締めました。この月度の勤怠は変更できなくなり、" \
                        "集計値と日別の値は今の勤務ルール（所定労働時間 #{helpers.format_duration(closing.scheduled_work_minutes)}）で固定しました。"
  rescue MonthlyClosing::Error => e
    redirect_to admin_monthly_summaries_path(month: month_param), alert: "締められませんでした：#{e.message}", status: :see_other
  end

  def destroy
    closing = MonthlyClosing.active.find_by(year: @year, month: @month)
    unless closing
      return redirect_to admin_monthly_summaries_path(month: month_param), status: :see_other,
                         alert: "締めを解除できませんでした：この月度は締められていません（他の管理者がすでに解除した可能性があります）。"
    end

    closing.reopen!(by: current_user)
    period = WorkRules.current.period_from_param(month_param)
    redirect_to admin_monthly_summaries_path(month: month_param), status: :see_other,
                notice: "#{closing.label}の締めを解除しました。この月度（#{MonthlyClosing.range_label(period)}）は、" \
                        "今の勤務ルールで計算し直して表示します。勤怠の修正・申請の承認ができるようになりました。"
  rescue MonthlyClosing::Error => e
    redirect_to admin_monthly_summaries_path(month: month_param), alert: "締めを解除できませんでした：#{e.message}", status: :see_other
  end

  private

  def set_month
    @year, @month = AttendancePeriod.parse_year_month(params[:month])
    redirect_to admin_monthly_summaries_path, alert: "締める月度を正しく指定してください。", status: :see_other unless @year
  end

  def month_param
    @year ? format("%04d-%02d", @year, @month) : nil
  end
end
