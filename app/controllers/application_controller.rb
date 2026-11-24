class ApplicationController < ActionController::Base
  include Authentication

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # 同時に届いた書き込みがデータベースのロックを取れなかったとき（SQLite の database is locked など）、
  # 500 の例外画面ではなく、元の画面に戻してメッセージを出す。
  # 申請・承認など、入力を残したい処理は各モデルで先に捕まえてエラーとして表示する。これは最後の受け皿。
  rescue_from DatabaseLockError, with: :handle_database_lock_conflict

  helper_method :pending_approval_count

  private

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
