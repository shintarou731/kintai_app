# 「すべて既読にする」（F16）：自分の未読の通知をまとめて既読にする。
# until_id … 画面を開いた時点の最新の通知の ID。これより後に届いた通知は、まだ見ていないので未読のまま残す（無ければ全部）
class Notifications::BulkReadingsController < ApplicationController
  # GET（URL を直接開いた・再読み込みした）ときは、既読にせずに一覧へ戻す
  def show
    redirect_to notifications_path
  end

  def create
    now = Time.current
    unread = current_user.notifications.unread
    unread = unread.where(id: ..params[:until_id].to_i) if params[:until_id].to_s.match?(/\A\d+\z/)
    count = unread.update_all(read_at: now, updated_at: now)
    message = count.positive? ? "#{count}件の通知を既読にしました。" : "未読の通知はありません。"
    # 押した画面（通知の一覧、またはヘッダーのベルを開いた画面）に戻る
    redirect_back_or_to notifications_path, notice: message, status: :see_other
  end
end
