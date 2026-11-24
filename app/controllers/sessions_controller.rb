# ログイン・ログアウト
class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]
  before_action :redirect_to_setup_if_required, only: %i[new create]
  before_action :redirect_if_logged_in, only: %i[new create]

  rate_limit to: 10, within: 3.minutes, only: :create,
             with: -> { redirect_to login_path, alert: "ログインの試行回数が多すぎます。しばらく待ってから再度お試しください。" }

  def new
  end

  def create
    user = User.authenticate_by_credentials(params[:email], params[:password])

    if user&.active?
      return_to = start_session_for(user)
      redirect_to return_to.presence || root_path, notice: "ログインしました。"
    elsif user
      # パスワードが正しい場合だけ、無効化されていることを伝える
      render_login_error User::INACTIVE_LOGIN_MESSAGE
    else
      render_login_error "メールアドレスまたはパスワードが正しくありません。"
    end
  end

  def destroy
    terminate_session
    redirect_to login_path, notice: "ログアウトしました。", status: :see_other
  end

  private

  def render_login_error(message)
    @email = params[:email]
    flash.now[:alert] = message
    render :new, status: :unprocessable_entity
  end

  def redirect_to_setup_if_required
    redirect_to setup_path if User.setup_required?
  end

  def redirect_if_logged_in
    redirect_to root_path if logged_in?
  end
end
