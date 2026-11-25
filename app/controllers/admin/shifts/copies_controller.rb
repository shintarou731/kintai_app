# 前週のシフトを今の週にまとめてコピーする（F11）。シフト表の「前週をコピー」から送る（week は今の週の月曜日）。
# すでにシフトがあるマスは上書きしない（件数を知らせる）。コピーしたシフトは下書き
class Admin::Shifts::CopiesController < Admin::BaseController
  include Admin::ShiftWeekParam

  # コピーの画面は無いので、URL を直接開いたときはシフト表に戻す
  def show
    redirect_to_shift_board
  end

  def create
    week = requested_week
    return redirect_to_shift_board(alert: INVALID_WEEK_MESSAGE) if week.nil?

    copy = ShiftWeekCopy.new(week_start: week, admin: current_user)
    if copy.save
      redirect_to_shift_board(week, notice: success_message(copy))
    else
      redirect_to_shift_board(week, alert: copy.errors.full_messages.join(" "))
    end
  end

  private

  def success_message(copy)
    result = copy.result
    source = copy.source_range
    message = +"前週（#{I18n.l(source.begin, format: :short)}〜#{I18n.l(source.end, format: :short)}）のシフトを #{result.copied}件 コピーしました（下書き）。"
    if (skipped = ShiftWeekCopy.skipped_summary(result))
      message << "#{skipped} はコピーしていません（上書きはしません）。"
    end
    message << "無効な従業員のシフト #{result.inactive}件 はコピーしていません。" if result.inactive.positive?
    if (half_day = ShiftWeekCopy.half_day_summary(result))
      message << "#{half_day} はコピーしました。シフト表で「半休と重なる」と出ているマスの時間を確かめてください。"
    end
    message << "内容を確かめてから、週を「公開」してください。"
  end
end
