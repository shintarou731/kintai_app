# 存在しない申請や、他の人の申請（例：/requests/9999）にアクセスされたとき、
# 例外画面ではなく「申請」一覧に戻して知らせる（他の人の申請があるかどうかも明かさない）
module ApprovalRequestNotFound
  extend ActiveSupport::Concern

  NOT_FOUND_MESSAGE = "指定された申請が見つかりません。一覧から選び直してください。".freeze

  included do
    rescue_from ActiveRecord::RecordNotFound, with: :redirect_approval_request_not_found
  end

  private

  def redirect_approval_request_not_found
    redirect_to approval_requests_path, alert: NOT_FOUND_MESSAGE, status: :see_other
  end
end
