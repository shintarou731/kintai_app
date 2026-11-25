# 通知を開く（F16）：その通知を既読にして、関連する画面（申請の詳細・シフトなど）へ移る。
# 自分の通知だけを開ける。他の人の通知や存在しない通知は、既読にせず一覧へ戻す（他の人の通知があるかどうかも明かさない）
class Notifications::ReadingsController < ApplicationController
  NOT_FOUND_MESSAGE = "指定された通知が見つかりません。一覧から選び直してください。".freeze

  # GET（URL を直接開いた・再読み込みした）ときは、既読にせずに一覧へ戻す
  def show
    redirect_to notifications_path
  end

  def create
    notification = current_user.notifications.find_by(id: params[:notification_id])
    return redirect_to notifications_path, alert: NOT_FOUND_MESSAGE, status: :see_other if notification.nil?

    notification.mark_read!
    redirect_to notification.target_path || notifications_path, status: :see_other
  end
end
