# 打刻修正申請の入力と送信。勤怠履歴の各日の「修正申請」や「申請」画面から、対象日を指定して開く
class AttendanceCorrectionRequestsController < ApplicationController
  before_action :set_target_date

  def new
    @correction = AttendanceCorrectionRequest.build_for(current_user, @target_date)
  end

  def create
    @correction = current_user.attendance_correction_requests.new(correction_params.merge(target_date: @target_date))

    if @correction.submit
      flash[:highlight_request_id] = @correction.id
      redirect_to approval_requests_path,
                  notice: "#{date_label(@target_date)} の打刻修正を申請しました（承認待ち）。承認されるまで勤怠記録は変わりません。"
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  # 対象日を確かめる。日付として読めない・未来の日・すでに承認待ちの申請がある日は、入力画面を出さない
  def set_target_date
    raw = action_name == "create" ? params.dig(:attendance_correction_request, :target_date) : params[:date]
    @target_date = parse_date(raw)

    if @target_date.nil?
      redirect_to approval_requests_path, alert: "修正申請する日付を正しく指定してください。"
    elsif @target_date > Date.current
      redirect_to attendances_path(month: WorkRules.current.period_containing(@target_date).to_param),
                  alert: "未来の日付（#{date_label(@target_date)}）は修正申請できません。今日までの日付を選んでください。"
    elsif (pending = current_user.attendance_correction_requests.pending.find_by(target_date: @target_date))
      redirect_to approval_request_path(pending),
                  alert: "#{date_label(@target_date)} にはすでに承認待ちの修正申請があります。内容を変えたい場合は、この申請を取り下げてから出し直してください。"
    end
  end

  def parse_date(value)
    Date.iso8601(value.to_s) if value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
  rescue Date::Error
    nil
  end

  def date_label(date)
    I18n.l(date, format: :short_with_day)
  end

  # パラメーターが欠けていても 400 にせず、入力画面にエラーを出す
  def correction_params
    params.fetch(:attendance_correction_request, {})
          .permit(:clock_in_time, :clock_out_time, :clock_out_day, :reason,
                  break_inputs: %i[start_time start_day end_time end_day])
          .to_h
  end
end
