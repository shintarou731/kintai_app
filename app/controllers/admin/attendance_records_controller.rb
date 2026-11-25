# 管理者による勤怠の直接修正・削除（F14）。月次集計の日別の勤怠の「修正」から開く。理由が必須で、履歴（AttendanceEdit）を残す
class Admin::AttendanceRecordsController < Admin::BaseController
  before_action :set_record

  def edit
    @record_editor = AttendanceRecordEditor.new(user: @user, work_date: @date, editor: current_user).prefill
  end

  def update
    @record_editor = AttendanceRecordEditor.new(user: @user, work_date: @date, editor: current_user, **editor_params)
    if @record_editor.save
      edit = @record_editor.edit
      redirect_to admin_monthly_summary_path(@user, month: @period.to_param), status: :see_other,
                  notice: "#{@user.name} さんの #{date_label} の勤怠を#{edit.operation == 'created' ? '作成' : '修正'}しました（理由と修正前・修正後を履歴に残しました）。"
    else
      render_edit_with_errors("保存できませんでした")
    end
  end

  def destroy
    @record_editor = AttendanceRecordEditor.new(user: @user, work_date: @date, editor: current_user,
                                                reason: delete_params[:reason].to_s, record_token: delete_params[:record_token].to_s)
    if @record_editor.destroy_record
      redirect_to admin_monthly_summary_path(@user, month: @period.to_param), status: :see_other,
                  notice: "#{@user.name} さんの #{date_label} の勤怠を削除しました（理由と削除前の記録を履歴に残しました）。"
    else
      @delete_errors = @record_editor.errors.full_messages
      @record_editor = AttendanceRecordEditor.new(user: @user, work_date: @date, editor: current_user).prefill
      render_edit_with_errors("削除できませんでした", @delete_errors)
    end
  end

  private

  def set_record
    @user = User.find_by(id: params[:user_id])
    @date = parse_date(params[:date])
    return redirect_to admin_monthly_summaries_path, alert: "指定された従業員・日付が見つかりません。" if @user.nil? || @date.nil?

    @rules = WorkRules.current
    @period = @rules.period_containing(@date)
    @edits = AttendanceEdit.where(user: @user, work_date: @date).includes(:editor).recent_first.to_a
  end

  def render_edit_with_errors(title, messages = @record_editor.errors.full_messages)
    flash.now[:alert] = "#{title}：#{messages.join(' ')}"
    render :edit, status: :unprocessable_entity
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end

  def date_label
    l(@date, format: :short_with_day)
  end

  # パラメーターが欠けていても 400 にせず、入力画面にエラーを出す
  def editor_params
    raw = params[:attendance_record_editor]
    return {} unless raw.is_a?(ActionController::Parameters)

    raw.permit(:clock_in_time, :clock_out_time, :clock_out_day, :reason, :record_token,
               break_inputs: %i[start_time start_day end_time end_day]).to_h.symbolize_keys
  end

  def delete_params
    raw = params[:attendance_record_delete]
    raw.is_a?(ActionController::Parameters) ? raw.permit(:reason, :record_token) : {}
  end
end
