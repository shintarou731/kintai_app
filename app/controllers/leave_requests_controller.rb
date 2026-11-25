# 「休暇」画面：休暇の申請と、自分の休暇の一覧。休暇の詳細・取り下げ・取消申請は「申請」の詳細（/requests/:id）で行う
class LeaveRequestsController < ApplicationController
  FILTERS = %w[upcoming all].freeze

  def index
    @leave = LeaveRequest.build_for(current_user)
    load_leaves
  end

  def create
    @leave = current_user.leave_requests.new(leave_params)

    if @leave.submit
      flash[:highlight_request_id] = @leave.id
      redirect_to leave_requests_path,
                  notice: "#{@leave.description}を申請しました（承認待ち）。承認されると勤怠履歴に表示されます。"
    else
      load_leaves
      flash.now[:alert] = "休暇を申請できませんでした。入力内容を確認してください。"
      render :index, status: :unprocessable_entity
    end
  end

  private

  # 一覧：「これからの休暇」（終了日が今日以降で、承認待ち・有効な承認済みのもの）と「すべて」。
  # 取り下げ・却下・取消済みの休暇は休む予定ではないので、「すべて」にだけ出す
  def load_leaves
    @filter = FILTERS.include?(params[:status]) ? params[:status] : "upcoming"
    leaves = current_user.leave_requests
    upcoming = leaves.blocking.where(end_date: Date.current..)
    @counts = { "upcoming" => upcoming.count, "all" => leaves.count }
    scope = @filter == "upcoming" ? upcoming.order(:target_date, :id) : leaves.order(target_date: :desc, id: :desc)
    @leaves = scope.includes(:cancellation_requests, :reviewer).to_a
    @highlight_id = flash[:highlight_request_id]
    @paid_leave = PaidLeaveAccount.new(current_user)
  end

  # パラメーターが欠けていても 400 にせず、入力画面にエラーを出す
  def leave_params
    params.fetch(:leave_request, {}).permit(:leave_type, :target_date, :end_date, :day_part, :reason).to_h
  end
end
