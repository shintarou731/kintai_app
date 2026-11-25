# 申請の承認・却下（管理者）。承認画面の詳細のフォームから送る
class Admin::ApprovalRequests::ReviewsController < Admin::BaseController
  include Admin::ApprovalRequestNotFound

  def create
    approval_request = ApprovalRequest.find(params[:approval_request_id])
    @review = ApprovalReview.new(approval_request: approval_request, reviewer: current_user, **review_params)

    if @review.save
      redirect_to admin_approval_requests_path, notice: success_message(@review), status: :see_other
    else
      @approval_request = @review.approval_request
      @active_admin_count = User.active_admins.count
      # エラーは画面下部の「承認・却下」欄にも出すが、再表示した画面の先頭でも分かるように上部のメッセージで知らせる
      flash.now[:alert] = "#{@review.reject? ? '却下' : '承認'}できませんでした：#{@review.errors.full_messages.join(' ')}"
      render "admin/approval_requests/show", status: :unprocessable_entity
    end
  end

  private

  # パラメーターが欠けていても 400 にせず、詳細画面にエラーを出す
  def review_params
    raw = params[:approval_review]
    return {} unless raw.is_a?(ActionController::Parameters)

    raw.permit(:decision, :comment).to_h.symbolize_keys
  end

  def success_message(review)
    request = review.approval_request
    label = "#{request.user.name} さんの #{request.target_label} の#{request.kind_label}申請"
    if review.approve?
      "#{label}を承認しました。#{request.approval_result_note}"
    else
      "#{label}を却下しました。#{request.rejection_result_note}"
    end
  end
end
