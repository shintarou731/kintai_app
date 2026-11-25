# ログイン後のホーム画面：現在時刻と打刻ボタン、今日と次回のシフト、今日の勤務、有給休暇の残日数を表示する
class HomeController < ApplicationController
  def show
    @time_clock = TimeClock.new(current_user)
    # ホームから退勤できなくなった退勤漏れの勤務と、その日の承認待ちの修正申請（お知らせから申請へ案内する）
    @missing_clock_outs = @time_clock.missing_clock_outs.to_a
    @pending_corrections_by_date = current_user.attendance_correction_requests.pending
                                               .where(target_date: @missing_clock_outs.map(&:work_date))
                                               .index_by(&:target_date)
    @paid_leave = PaidLeaveAccount.new(current_user, today: @time_clock.now.to_date)
    @shift_summary = HomeShiftSummary.new(current_user, now: @time_clock.now)
  end
end
