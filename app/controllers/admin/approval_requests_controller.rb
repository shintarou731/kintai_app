# 承認画面（管理者）：従業員の申請の一覧と詳細。承認・却下は Admin::ApprovalRequests::ReviewsController
class Admin::ApprovalRequestsController < Admin::BaseController
  include Admin::ApprovalRequestNotFound

  FILTERS = %w[pending processed].freeze

  def index
    @filter = FILTERS.include?(params[:status]) ? params[:status] : "pending"
    @counts = { "pending" => ApprovalRequest.pending.count, "processed" => ApprovalRequest.processed.count }
    requests = if @filter == "pending"
      ApprovalRequest.pending.oldest_first
    else
      ApprovalRequest.processed.recently_processed_first
    end
    @requests = requests.includes(:user, :reviewer).to_a
    ApprovalRequest.preload_details(@requests)
    @active_admin_count = User.active_admins.count
  end

  def show
    @approval_request = ApprovalRequest.includes(:user, :reviewer).find(params[:id])
    @review = ApprovalReview.new(approval_request: @approval_request, reviewer: current_user)
    @active_admin_count = User.active_admins.count
    # 承認済みの休暇には、直接取消のフォームを出す
    if @approval_request.is_a?(LeaveRequest)
      @direct_cancellation = LeaveDirectCancellation.new(leave_request: @approval_request, admin: current_user)
    end
  end
end
