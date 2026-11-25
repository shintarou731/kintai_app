# 管理者による有給休暇の付与（F10）：残日数・付与の一覧・履歴の表示（index）、付与の登録（create）。
# 誤登録の削除は Admin::Employees::PaidLeaveGrantRemovalsController（理由を入れて送り、記録を残す）
class Admin::Employees::PaidLeaveGrantsController < Admin::BaseController
  include Admin::EmployeeNotFound

  before_action :set_employee

  def index
    @grant = PaidLeaveGrant.build_for(@employee)
    load_account
  end

  def create
    @grant = @employee.paid_leave_grants.new(grant_params.merge(granted_by: current_user))

    if @grant.save
      # 付与が確定した後に本人へ通知する（通知が作れなくても付与は取り消さない。F16）
      Notifier.paid_leave_granted(@grant)
      redirect_to admin_employee_paid_leave_grants_path(@employee),
                  notice: "#{@employee.name} さんに有給休暇を #{LeaveRequest.format_days(@grant.granted_days)} 付与しました" \
                          "（#{I18n.l(@grant.granted_on)} 付与・#{I18n.l(@grant.expires_on)} まで有効）。"
    else
      load_account
      flash.now[:alert] = "有給休暇を付与できませんでした。入力内容を確認してください。"
      render :index, status: :unprocessable_entity
    end
  end

  private

  def set_employee
    @employee = User.find(params[:employee_id])
  end

  def load_account
    @employee.paid_leave_grants.reset
    @account = PaidLeaveAccount.new(@employee, grants: PaidLeaveGrant.kept.where(user: @employee).includes(:granted_by).chronological.to_a,
                                               removed_grants: @employee.removed_paid_leave_grants.includes(:removed_by, :granted_by).to_a)
  end

  # パラメーターが欠けていても 400 にせず、入力画面にエラーを出す
  def grant_params
    params.fetch(:paid_leave_grant, {}).permit(:granted_on, :days, :expires_on, :note).to_h
  end
end
