# 従業員管理：一覧・登録・編集（無効化とパスワード再設定は Admin::Employees 配下）
class Admin::EmployeesController < Admin::BaseController
  include Admin::EmployeeNotFound

  STATUS_FILTERS = %w[all active inactive].freeze

  # アカウント情報画面（/account）から自分の編集画面を開いたことを示す値。
  # 戻り先の URL そのものは受け取らず、この固定値のときだけ戻り先をアカウント情報にする（外部の URL へ飛ばされない）
  FROM_ACCOUNT = "account".freeze

  before_action :set_employee, only: %i[edit update]
  helper_method :from_account?, :back_path

  def index
    @status = STATUS_FILTERS.include?(params[:status]) ? params[:status] : "all"
    @counts = { "all" => User.count, "active" => User.active.count, "inactive" => User.inactive.count }
    @employees = filtered_users.ordered_for_list.to_a
    # 有給休暇の残日数と当年度の取得日数（F10）。付与と休暇をまとめて読む
    @paid_leaves = PaidLeaveAccount.for_users(@employees)
    @fiscal_year = PaidLeaveAccount.fiscal_year_range(Date.current)
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
      redirect_to back_path, notice: "#{@employee.name} さんの情報を更新しました。"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_employee
    @employee = User.find(params[:id])
  end

  # 本人の編集画面を、アカウント情報画面から開いたとき（他人の編集画面では、値があっても無視する）
  def from_account?
    params[:from] == FROM_ACCOUNT && @employee == current_user
  end

  def back_path
    from_account? ? account_path : admin_employees_path
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
