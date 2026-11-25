# シフトパターンの管理（F11）：一覧と登録（index / create）、変更（edit / update）、削除（destroy）。
# パターンを変更・削除しても、すでに作ったシフトは変わらない（割り当てたときに時刻と休憩をシフトに写しているため）。
# ?week=2026-11-23 を付けて開くと、シフト表のその週に戻るリンクを出す
class Admin::ShiftPatternsController < Admin::BaseController
  include Admin::ShiftWeekParam

  before_action :set_week
  before_action :set_pattern, only: %i[edit update destroy]

  def index
    @pattern = ShiftPattern.new(break_minutes: WorkRules.current.standard_break_minutes)
    load_patterns
  end

  def create
    @pattern = ShiftPattern.new(pattern_params)
    if save_pattern(@pattern)
      redirect_to admin_shift_patterns_path(week_param), notice: "シフトパターン「#{@pattern.name}」（#{label(@pattern)}・休憩#{@pattern.break_minutes}分）を登録しました。"
    else
      load_patterns
      flash.now[:alert] = "シフトパターンを登録できませんでした。入力内容を確認してください。"
      render :index, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    @pattern.assign_attributes(pattern_params)
    if save_pattern(@pattern)
      redirect_to admin_shift_patterns_path(week_param), notice: "シフトパターン「#{@pattern.name}」を #{label(@pattern)}（休憩#{@pattern.break_minutes}分）に変更しました。" \
                                                             "すでに作ったシフトは変わりません。"
    else
      flash.now[:alert] = "シフトパターンを変更できませんでした。入力内容を確認してください。"
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @pattern.destroy!
    redirect_to admin_shift_patterns_path(week_param), status: :see_other,
                                                       notice: "シフトパターン「#{@pattern.name}」を削除しました。すでに作ったシフトは変わりません。"
  end

  private

  def set_week
    @week = params[:week].present? ? ShiftBoard.parse_week(params[:week]) : nil
  end

  def week_param
    @week ? { week: @week.iso8601 } : {}
  end

  def set_pattern
    @pattern = ShiftPattern.find_by(id: params[:id])
    return unless @pattern.nil?

    redirect_to admin_shift_patterns_path(week_param), status: :see_other,
                                                       alert: "指定されたシフトパターンが見つかりません（すでに削除されている可能性があります）。"
  end

  def load_patterns
    @patterns = ShiftPattern.ordered.to_a
  end

  # 名前が同時に登録されたとき（一意の索引）も、入力画面にエラーを出す
  def save_pattern(pattern)
    pattern.save
  rescue ActiveRecord::RecordNotUnique
    pattern.errors.add(:name, :taken)
    false
  end

  def label(pattern)
    Shift.range_label(pattern.start_minute, pattern.end_minute)
  end

  # パラメーターが欠けていても 400 にせず、入力画面にエラーを出す
  def pattern_params
    params.fetch(:shift_pattern, {}).permit(:name, :start_time, :end_time, :break_minutes).to_h
  end
end
