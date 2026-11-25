# 承認済みの休暇の直接取消（管理者）。承認画面の休暇の詳細（/admin/approvals/:id）のフォームから送る。
# 従業員ロールは Admin::BaseController で拒否される（ホームに戻し、休暇は変わらない）
class Admin::ApprovalRequests::CancellationsController < Admin::BaseController
  include Admin::ApprovalRequestNotFound

  # 取消の画面は無いので、URL を直接開いたときは休暇の詳細（取消のフォームがある画面）へ戻す
  def show
    leave = LeaveRequest.find(params[:approval_request_id])
    redirect_to admin_approval_request_path(leave), status: :see_other
  end

  def create
    leave = LeaveRequest.find(params[:approval_request_id])
    @direct_cancellation = LeaveDirectCancellation.new(leave_request: leave, admin: current_user, reason: reason_param)

    if @direct_cancellation.save
      redirect_to admin_approval_request_path(leave), notice: success_message(@direct_cancellation), status: :see_other
    else
      @approval_request = LeaveRequest.includes(:user, :reviewer, :cancelled_by, :cancellation_requests).find(leave.id)
      @review = ApprovalReview.new(approval_request: @approval_request, reviewer: current_user)
      @active_admin_count = User.active_admins.count
      flash.now[:alert] = "休暇を取り消せませんでした：#{@direct_cancellation.errors.full_messages.join(' ')}"
      render "admin/approval_requests/show", status: :unprocessable_entity
    end
  end

  private

  # パラメーターが欠けていても 400 にせず、詳細画面にエラーを出す
  def reason_param
    raw = params[:leave_direct_cancellation]
    raw.is_a?(ActionController::Parameters) ? raw[:reason].to_s : ""
  end

  def success_message(cancellation)
    leave = cancellation.leave_request
    message = "#{leave.user.name} さんの #{leave.description}を取り消しました。本人の勤怠履歴の該当日から休暇の表示が消えます。"
    message += "有給休暇の残日数に#{LeaveRequest.format_days(leave.chargeable_days)}戻しました。" if leave.leave_paid? && leave.chargeable_days.positive?
    message += "承認待ちだった取消申請も、処理済みにしました。" if cancellation.closed_cancellation_requests.any?
    message
  end
end
