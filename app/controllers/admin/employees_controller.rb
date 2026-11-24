# 従業員管理：一覧・登録・編集（無効化とパスワード再設定は Admin::Employees 配下）
class Admin::EmployeesController < Admin::BaseController
  include Admin::EmployeeNotFound

  STATUS_FILTERS = %w[all active inactive].freeze

  before_action :set_employee, only: %i[edit update]

  def index
    @status = STATUS_FILTERS.include?(params[:status]) ? params[:status] : "all"
    @counts = { "all" => User.count, "active" => User.active.count, "inactive" => User.inactive.count }
    @employees = filtered_users.ordered_for_list
  end

  def new
    @employee = User.new
  end

  def create
    @employee = User.new(create_params)

    if @employee.save(context: User::STAFF_FORM_CONTEXT)
      redirect_to admin_employees_path,
                  notice: "#{@employee.name} さんを登録しました。初期パスワードを本人にお伝えください。"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    @employee.assign_attributes(update_params)
    @employee.editor = current_user

    if @employee.save_keeping_active_admin(context: User::STAFF_FORM_CONTEXT)
      redirect_to admin_employees_path, notice: "#{@employee.name} さんの情報を更新しました。"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_employee
    @employee = User.find(params[:id])
  end

  def filtered_users
    case @status
    when "active" then User.active
    when "inactive" then User.inactive
    else User.all
    end
  end

  def create_params
    params.require(:user).permit(:name, :email, :password, :role, :employment_type, :hired_on)
  end

  def update_params
    params.require(:user).permit(:name, :email, :role, :employment_type, :hired_on)
  end
end
