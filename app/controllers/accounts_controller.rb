# ログイン中のユーザー本人のアカウント情報（閲覧専用）。
# 表示するのは常に current_user で、URL やパラメーターで他の人を指定することはできない。
# 有給休暇の値は「休暇」画面・従業員一覧と同じ PaidLeaveAccount で求める
class AccountsController < ApplicationController
  def show
    @user = current_user
    @paid_leave = PaidLeaveAccount.new(@user)
  end
end
