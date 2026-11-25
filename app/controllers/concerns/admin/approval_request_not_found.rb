# 承認画面で、存在しない申請 ID（例：/admin/approvals/9999）にアクセスされたとき、
# 例外画面ではなく承認画面の一覧に戻して知らせる
module Admin::ApprovalRequestNotFound
  extend ActiveSupport::Concern

  NOT_FOUND_MESSAGE = "指定された申請が見つかりません。一覧から選び直してください。".freeze

  included do
    rescue_from ActiveRecord::RecordNotFound, with: :redirect_approval_request_not_found
  end

  private

  def redirect_approval_request_not_found
    redirect_to admin_approval_requests_path, alert: NOT_FOUND_MESSAGE, status: :see_other
  end
end
