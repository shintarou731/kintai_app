# ログイン状態の管理（セッションに user_id を保持する）と、
# 未ログイン・初期セットアップ未完了時のリダイレクトを担う。
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :current_user, :logged_in?
  end

  class_methods do
    # ログイン不要な画面で使う（ログイン画面・初期セットアップ画面など）
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = session[:user_id] && User.active.find_by(id: session[:user_id])
  end

  def logged_in?
    current_user.present?
  end

  def require_authentication
    return if logged_in?

    if session[:user_id] && User.inactive.exists?(id: session[:user_id])
      # ログイン中に無効化されたユーザーは、次の操作時にログアウトさせる
      terminate_session
      redirect_to login_path, alert: User::INACTIVE_LOGIN_MESSAGE
    elsif User.setup_required?
      redirect_to setup_path
    else
      session[:return_to_after_login] = request.fullpath if request.get?
      redirect_to login_path, alert: "ログインしてください。"
    end
  end

  # セッション固定攻撃を防ぐため、ログイン時にセッションを作り直す
  def start_session_for(user)
    return_to = session[:return_to_after_login]
    reset_session
    session[:user_id] = user.id
    @current_user = user
    return_to
  end

  def terminate_session
    reset_session
    @current_user = nil
  end
end
