# 従業員アカウントの有効化（create）・無効化（destroy）
class Admin::Employees::ActivationsController < Admin::BaseController
  include Admin::EmployeeNotFound

  before_action :set_employee

  def create
    if @employee.activate
      redirect_to edit_admin_employee_path(@employee), notice: "#{@employee.name} さんを有効にしました。ログインできるようになります。"
    else
      redirect_with_errors
    end
  end

  def destroy
    if @employee.deactivate
      redirect_to edit_admin_employee_path(@employee), notice: "#{@employee.name} さんを無効にしました。以後ログインできません。",
                                                     status: :see_other
    else
      redirect_with_errors
    end
  end

  private

  def set_employee
    @employee = User.find(params[:employee_id])
    @employee.editor = current_user
  end

  def redirect_with_errors
    redirect_to edit_admin_employee_path(@employee), alert: @employee.errors.full_messages.join(" "), status: :see_other
  end
end
