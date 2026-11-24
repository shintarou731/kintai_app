# 管理者用画面の共通処理：管理者以外はホームに戻す
class Admin::BaseController < ApplicationController
  before_action :require_admin

  private

  def require_admin
    return if current_user.admin?

    redirect_to root_path, alert: "この画面を表示する権限がありません。"
  end
end
