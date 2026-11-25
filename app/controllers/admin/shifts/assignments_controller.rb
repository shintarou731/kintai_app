# シフトパターンをマスに割り当てる（F11）。シフト表で「パターンで割り当て」を選んでマスを押したときに送る。
# 割り当てた後は、押したときと同じシフト表の URL に戻す（Turbo のページの更新（morph）で、表のスクロール位置を保ったまま変わる）。
# 結果のメッセージは、ページ上部に差し込まず、画面上部に重ねて出すメッセージ（トースト）で知らせる（表の位置がずれないように）
class Admin::Shifts::AssignmentsController < Admin::BaseController
  include Admin::ShiftWeekParam

  # 割り当ての画面は無いので、URL を直接開いたときはシフト表に戻す
  def index
    redirect_to_shift_board
  end

  def create
    user = User.find_by(id: params[:user_id])
    date = parse_date(params[:date])
    pattern = ShiftPattern.find_by(id: params[:pattern_id])
    return redirect_to_shift_board(alert: "割り当てるマスが見つかりません。シフト表から選び直してください。") if user.nil? || date.nil?

    week = ShiftBoard.week_start_for(date)
    if pattern.nil?
      return redirect_to shift_board_path(week), status: :see_other,
                                                 alert: "割り当てるシフトパターンが見つかりません（削除された可能性があります）。パターンを選び直してください。"
    end

    assignment = ShiftAssignment.new(user: user, date: date, pattern: pattern, admin: current_user,
                                     expected_lock_version: params[:lock_version])
    target = "#{I18n.l(date, format: :short_with_day)} #{user.name} さん"
    if !assignment.save
      flash[:toast_alert] = assignment.errors.full_messages.join(" ")
    elsif assignment.unchanged?
      flash[:toast_notice] = "#{target}には、すでに「#{pattern.name}」（#{pattern_label(pattern)}）が入っています。"
    elsif (note = assignment.shift.half_day_overlap_note)
      flash[:toast_alert] = "#{target}に「#{pattern.name}」（#{pattern_label(pattern)}）を割り当てました（下書き）。#{note}"
    else
      flash[:toast_notice] = "#{target}に「#{pattern.name}」（#{pattern_label(pattern)}）を割り当てました（下書き）。"
    end
    redirect_to shift_board_path(week, pattern: pattern), status: :see_other
  end

  private

  def parse_date(value)
    Date.strptime(value.to_s, "%Y-%m-%d")
  rescue Date::Error
    nil
  end

  def pattern_label(pattern)
    Shift.range_label(pattern.start_minute, pattern.end_minute)
  end
end
