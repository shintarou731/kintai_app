# ログイン中のユーザー本人によるパスワード変更
class PasswordsController < ApplicationController
  def edit
    @user = current_user
  end

  def update
    @user = current_user

    if @user.change_password(current_password: password_params[:current_password],
                             new_password: password_params[:password],
                             new_password_confirmation: password_params[:password_confirmation].to_s)
      redirect_to root_path, notice: "パスワードを変更しました。"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def password_params
    params.require(:user).permit(:current_password, :password, :password_confirmation)
  end
end
