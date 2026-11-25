# シフト作成（F11）：週のシフト表（index）と、マス（従業員 × 日付）ごとのシフトの登録（new / create）・変更（edit / update）・削除（destroy）。
#
# - 同時編集：変更・削除は、画面を開いた時点の lock_version を送る。その後に他の管理者が保存していれば保存せず、最新の内容を見せて知らせる
#   （409）。登録は、同じマスに他の管理者が先に登録していれば保存しない（user_id × work_date の一意の索引でも止める）。
class Admin::ShiftsController < Admin::BaseController
  include Admin::ShiftWeekParam

  CONFLICT_STATUS = :conflict

  before_action :set_shift, only: %i[edit update destroy]

  def index
    week = requested_week
    if week.nil?
      redirect_to admin_shifts_path, alert: INVALID_WEEK_MESSAGE
      return
    end

    @board = ShiftBoard.new(week_start: week)
    return if params[:pattern].blank?

    @brush = @board.patterns.find { |pattern| pattern.id.to_s == params[:pattern].to_s }
    flash.now[:alert] = "指定されたシフトパターンが見つかりません（削除された可能性があります）。パターンを選び直してください。" if @brush.nil?
  end

  def new
    user = User.find_by(id: params[:user_id])
    date = parse_date(params[:date])
    return redirect_to_shift_board(alert: "シフトを登録するマスが見つかりません。シフト表から選び直してください。") if user.nil? || date.nil?

    existing = Shift.find_by(user: user, work_date: date)
    return redirect_to edit_admin_shift_path(existing) if existing&.live?

    @shift = existing || Shift.new(user: user, work_date: date)
    clear_draft_times(@shift)
    @shift.break_minutes = WorkRules.current.standard_break_minutes
    render :new
  end

  def create
    attributes = shift_params
    user = User.find_by(id: attributes.delete(:user_id))
    date = parse_date(attributes.delete(:work_date))
    return redirect_to_shift_board(alert: "シフトを登録するマスが見つかりません。シフト表から選び直してください。") if user.nil? || date.nil?

    @shift = Shift.find_or_initialize_by(user_id: user.id, work_date: date)
    return render_create_conflict(@shift, date) if @shift.persisted? && @shift.live?

    @shift.user = user
    @shift.assign_attributes(attributes.merge(removed_at: nil, updated_by: current_user))
    @shift.created_by ||= current_user
    if @shift.save
      redirect_to shift_board_path(week_of(@shift)), notice: "#{cell_label(@shift)}のシフト（#{@shift.range_label}）を登録しました（下書き）。" \
                                                             "週を「公開」するまで、従業員には見えません。#{@shift.half_day_overlap_note}"
    else
      flash.now[:alert] = "シフトを登録できませんでした。入力内容を確認してください。"
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
    render_create_conflict(Shift.find_by(user_id: user.id, work_date: date), date)
  end

  def edit
  end

  def update
    attributes = shift_params.except(:user_id, :work_date)
    submitted = Shift.range_label(Shift.parse_clock_time(attributes[:start_time]), Shift.parse_clock_time(attributes[:end_time]))
    @shift.assign_attributes(attributes.merge(updated_by: current_user))
    if @shift.save
      redirect_to shift_board_path(week_of(@shift)), notice: update_notice(@shift)
    else
      flash.now[:alert] = "シフトを変更できませんでした。入力内容を確認してください。"
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::StaleObjectError
    render_update_conflict(@shift, submitted)
  end

  def destroy
    @shift.lock_version = params[:lock_version] if params[:lock_version].present?
    published = @shift.published_once?
    label = "#{cell_label(@shift)}のシフト（#{@shift.range_label}）"
    @shift.remove!(by: current_user)
    notice = if published
               "#{label}を削除しました。公開中のシフトのため、週を「公開」すると従業員の画面からも消えます（それまでは公開中の内容が見えます）。"
    else
               "#{label}を削除しました。"
    end
    redirect_to shift_board_path(week_of(@shift)), notice: notice, status: :see_other
  rescue ActiveRecord::StaleObjectError
    latest = Shift.find_by(id: @shift.id)
    if latest&.live?
      redirect_to edit_admin_shift_path(latest), status: :see_other,
                                                alert: "他の管理者が先にこのシフトを変更したため、削除しませんでした。最新の内容（#{latest.range_label}）を確認してから、もう一度お試しください。"
    else
      redirect_to shift_board_path(week_of(@shift)), status: :see_other, notice: "このシフトは、他の管理者がすでに削除しています。"
    end
  end

  private

  def set_shift
    @shift = Shift.includes(:user, :updated_by).find_by(id: params[:id])
    if @shift.nil?
      redirect_to_shift_board(alert: "指定されたシフトが見つかりません（他の管理者が削除した可能性があります）。シフト表で最新の状態を確認してください。")
    elsif @shift.removed?
      if request.get?
        redirect_to new_admin_shift_path(user_id: @shift.user_id, date: @shift.work_date.iso8601)
      else
        redirect_to shift_board_path(week_of(@shift)), status: :see_other,
                                                       alert: "このシフトは、他の管理者がすでに削除しています（削除予定）。シフト表で最新の状態を確認してください。"
      end
    end
  end

  # パラメーターが欠けていても 400 にせず、入力画面にエラーを出す
  def shift_params
    params.fetch(:shift, {}).permit(:user_id, :work_date, :start_time, :end_time, :break_minutes, :leave_acknowledged, :lock_version).to_h
  end

  def parse_date(value)
    Date.strptime(value.to_s, "%Y-%m-%d")
  rescue Date::Error
    nil
  end

  def week_of(shift)
    ShiftBoard.week_start_for(shift.work_date)
  end

  def cell_label(shift)
    "#{I18n.l(shift.work_date, format: :short_with_day)} #{shift.user.name} さん"
  end

  # 新しいマスとして入力する（削除予定の行を使い直すときも、入力欄は空から始める）
  def clear_draft_times(shift)
    shift.start_minute = nil
    shift.end_minute = nil
  end

  def update_notice(shift)
    message = "#{cell_label(shift)}のシフトを #{shift.range_label}（休憩#{shift.break_minutes}分）に変更しました。"
    if shift.published_once? && !shift.published_matches_draft?
      message += "公開中の内容（#{shift.published_range_label}）は、週を「公開」するまで変わりません。"
    end
    "#{message}#{shift.half_day_overlap_note}"
  end

  def render_create_conflict(latest, date)
    if latest.nil? || latest.removed?
      redirect_to_shift_board(ShiftBoard.week_start_for(date), alert: ShiftAssignment::CONFLICT_MESSAGE)
      return
    end

    @shift = latest
    @conflict = true
    flash.now[:alert] = "他の管理者が先にこのマスにシフト（#{latest.range_label}）を登録したため、登録しませんでした。" \
                        "最新の内容を表示しています。変える場合は、内容を確かめてから保存してください。"
    render :edit, status: CONFLICT_STATUS
  end

  def render_update_conflict(shift, submitted)
    latest = Shift.includes(:user, :updated_by).find_by(id: shift.id)
    if latest.nil? || latest.removed?
      redirect_to shift_board_path(week_of(shift)), status: :see_other,
                                                    alert: "このシフトは、他の管理者が先に削除したため、変更できませんでした。"
      return
    end

    @shift = latest
    @conflict = true
    by = latest.updated_by ? "#{latest.updated_by.name} さん" : "他の管理者"
    flash.now[:alert] = "#{by}が先にこのシフトを #{latest.range_label}（休憩#{latest.break_minutes}分）に変更したため、" \
                        "入力した内容#{"（#{submitted}）" if submitted}は保存していません。最新の内容を表示しています。変える場合は、もう一度入力して保存してください。"
    render :edit, status: CONFLICT_STATUS
  end
end
