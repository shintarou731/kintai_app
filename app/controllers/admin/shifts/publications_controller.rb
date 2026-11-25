# シフトの週単位の公開（F11）。シフト表の「この週を公開」から送る。公開するまで、シフトとその変更は従業員に見えない
class Admin::Shifts::PublicationsController < Admin::BaseController
  include Admin::ShiftWeekParam

  # 公開の画面は無いので、URL を直接開いたときはシフト表に戻す
  def show
    redirect_to_shift_board
  end

  def create
    week = requested_week
    return redirect_to_shift_board(alert: INVALID_WEEK_MESSAGE) if week.nil?

    publication = ShiftWeekPublication.new(week_start: week, admin: current_user)
    if publication.save
      record = publication.record
      redirect_to_shift_board(week, notice: "#{I18n.l(week, format: :short)}〜#{I18n.l(week + 6, format: :short)} のシフトを公開しました" \
                                            "（#{record.summary}）。従業員の画面に反映されます。")
    else
      redirect_to_shift_board(week, alert: publication.errors.full_messages.join(" "))
    end
  end
end
