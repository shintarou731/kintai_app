# 管理者による従業員のパスワード再設定
class Admin::Employees::PasswordsController < Admin::BaseController
  include Admin::EmployeeNotFound

  before_action :set_employee
  before_action :redirect_if_self

  def edit
  end

  def update
    if @employee.reset_password(params.dig(:user, :password))
      redirect_to edit_admin_employee_path(@employee),
                  notice: "#{@employee.name} さんのパスワードを再設定しました。新しいパスワードを本人にお伝えください。"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_employee
    @employee = User.find(params[:employee_id])
  end

  # 自分のパスワードは、現在のパスワードを確認する通常の変更画面で変える
  def redirect_if_self
    redirect_to edit_password_path if @employee == current_user
  end
end
