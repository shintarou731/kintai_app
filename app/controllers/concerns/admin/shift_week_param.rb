# シフト作成（F11）の画面で共通の、週（?week=2026-11-23）の読み取りと、シフト表への戻り先
module Admin::ShiftWeekParam
  extend ActiveSupport::Concern

  INVALID_WEEK_MESSAGE = "指定された週を表示できません。今週のシフト表を表示します。".freeze

  private

  # params[:week] の週の月曜日。指定が無ければ今週、解釈できない・範囲外なら nil
  def requested_week(value = params[:week])
    return ShiftBoard.week_start_for(Date.current) if value.blank?

    ShiftBoard.parse_week(value)
  end

  # シフト表の URL。パターンで割り当てている途中なら pattern も付ける（割り当ての後に同じ URL へ戻して、表を部分的に更新する）
  def shift_board_path(week, pattern: nil)
    admin_shifts_path({ week: week.iso8601, pattern: pattern&.id }.compact)
  end

  def redirect_to_shift_board(week = requested_week, **options)
    redirect_to shift_board_path(week || ShiftBoard.week_start_for(Date.current)), status: :see_other, **options
  end
end
