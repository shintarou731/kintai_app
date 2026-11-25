# 初期セットアップ：ユーザーが1人もいないときだけ、最初の管理者を作成できる。
class SetupsController < ApplicationController
  allow_unauthenticated_access
  before_action :redirect_if_setup_completed

  def show
    @user = User.new
  end

  def create
    @user = User.new(setup_params.merge(role: :admin))

    saved = User.transaction do
      # 同時送信で管理者が2人作られないよう、保存直前にも確認する
      raise ActiveRecord::Rollback unless User.setup_required?

      @user.save
    end

    if saved
      start_session_for(@user)
      redirect_to root_path, notice: "初期セットアップが完了しました。管理者としてログインしています。"
    elsif !User.setup_required?
      redirect_if_setup_completed
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def setup_params
    params.require(:user).permit(:name, :email, :password, :password_confirmation)
  end

  def redirect_if_setup_completed
    return if User.setup_required?

    if logged_in?
      redirect_to root_path, notice: "初期セットアップは完了しています。"
    else
      redirect_to login_path, alert: "初期セットアップは完了しています。ログインしてください。"
    end
  end
end
