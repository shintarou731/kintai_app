# 申請の取り下げ（本人だけ。承認待ちの申請だけ取り下げられる）
class ApprovalRequests::WithdrawalsController < ApplicationController
  include ApprovalRequestNotFound

  def create
    approval_request = current_user.approval_requests.find(params[:approval_request_id])
    label = "#{approval_request.target_label} の#{approval_request.kind_label}申請"

    if approval_request.withdraw
      redirect_to approval_request_path(approval_request), notice: "#{label}を取り下げました。#{approval_request.withdrawal_result_note}",
                                                           status: :see_other
    else
      redirect_to approval_request_path(approval_request),
                  alert: "#{label}は「#{approval_request.status_label}」のため、取り下げできません（取り下げられるのは承認待ちの申請だけです）。",
                  status: :see_other
    end
  end
end
