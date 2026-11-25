# 承認済みの休暇の取消申請（本人だけ。開始日が明日以降の休暇だけ）。休暇の詳細（/requests/:id）のフォームから送る
class LeaveRequests::CancellationsController < ApplicationController
  include ApprovalRequestNotFound

  # 取消申請の画面は無いので、URL を直接開いたときは休暇の詳細（取消申請のフォームがある画面）へ戻す。
  # 他の人の休暇や存在しない休暇なら、「申請」一覧に戻して知らせる（ApprovalRequestNotFound）
  def show
    leave = current_user.leave_requests.find(params[:leave_request_id])
    redirect_to approval_request_path(leave), status: :see_other
  end

  def create
    @approval_request = current_user.leave_requests.includes(:reviewer, :cancellation_requests).find(params[:leave_request_id])
    @cancellation = current_user.leave_cancellation_requests.new(leave_request_id: @approval_request.id, reason: reason_param)

    if @cancellation.submit
      redirect_to approval_request_path(@cancellation), status: :see_other,
                  notice: "#{@approval_request.description}の取消を申請しました（承認待ち）。承認されるまで休暇は有効です。"
    else
      flash.now[:alert] = "取消申請できませんでした：#{@cancellation.errors.full_messages.join(' ')}"
      render "approval_requests/show", status: :unprocessable_entity
    end
  end

  private

  # パラメーターが欠けていても 400 にせず、詳細画面にエラーを出す
  def reason_param
    raw = params[:leave_cancellation_request]
    raw.is_a?(ActionController::Parameters) ? raw[:reason].to_s : ""
  end
end
