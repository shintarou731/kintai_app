# アプリ内通知の一覧（F16）。自分が受け取った通知だけを、新しい順に1ページ Notification::PER_PAGE 件ずつ出す。
# ?filter=unread で未読だけ、?page=2 でページを選ぶ（範囲外のページは、いちばん近いページにする）
class NotificationsController < ApplicationController
  FILTERS = %w[all unread].freeze

  def index
    @filter = FILTERS.include?(params[:filter]) ? params[:filter] : "all"
    notifications = current_user.notifications
    @counts = { "all" => notifications.count, "unread" => notifications.unread.count }
    filtered = @filter == "unread" ? notifications.unread : notifications

    @total_pages = [ (@counts[@filter] + Notification::PER_PAGE - 1) / Notification::PER_PAGE, 1 ].max
    @page = params[:page].to_s.match?(/\A\d+\z/) ? params[:page].to_i.clamp(1, @total_pages) : 1
    @notifications = filtered.includes(:actor).recent_first
                             .offset((@page - 1) * Notification::PER_PAGE).limit(Notification::PER_PAGE).to_a
    # 「すべて既読にする」は、この画面を開いた時点までに届いた通知だけを既読にする（押す前に届いた新しい通知は未読のまま）
    @latest_id = notifications.maximum(:id)
  end
end
