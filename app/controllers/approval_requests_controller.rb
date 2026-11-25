# 自分の「申請」の一覧と詳細。本人の申請だけを表示する
class ApprovalRequestsController < ApplicationController
  include ApprovalRequestNotFound

  FILTERS = %w[all pending processed].freeze

  def index
    @filter = FILTERS.include?(params[:status]) ? params[:status] : "all"
    requests = current_user.approval_requests
    @counts = { "all" => requests.count, "pending" => requests.pending.count, "processed" => requests.processed.count }
    @requests = filtered(requests).includes(:reviewer).recent_first.to_a
    ApprovalRequest.preload_details(@requests)
    @highlight_id = flash[:highlight_request_id]
  end

  def show
    @approval_request = current_user.approval_requests.includes(:reviewer).find(params[:id])
    # 承認済みの休暇の詳細には、取消申請のフォームを出す
    @cancellation = LeaveCancellationRequest.new(leave_request_id: @approval_request.id) if @approval_request.is_a?(LeaveRequest)
  end

  private

  def filtered(requests)
    case @filter
    when "pending" then requests.pending
    when "processed" then requests.processed
    else requests
    end
  end
end
