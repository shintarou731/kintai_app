class ApplicationController < ActionController::Base
  include Authentication

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # 同時に届いた書き込みがデータベースのロックを取れなかったとき（SQLite の database is locked など）、
  # 500 の例外画面ではなく、元の画面に戻してメッセージを出す。
  # 申請・承認など、入力を残したい処理は各モデルで先に捕まえてエラーとして表示する。これは最後の受け皿。
  rescue_from DatabaseLockError, with: :handle_database_lock_conflict

  helper_method :pending_approval_count, :unread_notification_count, :menu_notifications, :latest_notification_id

  private

  # ヘッダーのベルのバッジに出す、自分の未読の通知の件数（F16）
  def unread_notification_count
    @unread_notification_count ||= current_user ? current_user.notifications.unread.count : 0
  end

  # ヘッダーのベルから開く一覧に出す、新しい通知（Notification::MENU_LIMIT 件まで）
  def menu_notifications
    @menu_notifications ||= current_user ? current_user.notifications.recent_first.limit(Notification::MENU_LIMIT).to_a : []
  end

  # 「すべて既読にする」で既読にする範囲（この画面を表示した時点で最新の通知）
  def latest_notification_id
    menu_notifications.first&.id
  end

  # ヘッダーの「承認」に出す、この管理者が処理できる承認待ちの件数（管理者だけ）。
  # 有効な管理者が2人以上なら、自分の申請（他の管理者が処理する）は数えない
  def pending_approval_count
    return 0 unless current_user&.admin?

    @pending_approval_count ||= ApprovalRequest.actionable_by(current_user).count
  end

  def handle_database_lock_conflict(error)
    raise error if request.get? || request.head?

    redirect_back_or_to root_path, alert: DatabaseLockError::MESSAGE, status: :see_other
  end
end
