# 誤って登録した有給休暇の付与の削除（管理者。F10）。
# - new：削除の確認画面。付与の内容・使用・削除後の残日数を見せ、理由（必須）を入れて送る。削除できない場合は理由を出す。
# - create：削除する（PaidLeaveGrantRemoval）。行は消さず、削除した管理者・日時・理由を記録する。
# 従業員ロールは Admin::BaseController で拒否される（ホームに戻し、付与は変わらない）。
class Admin::Employees::PaidLeaveGrantRemovalsController < Admin::BaseController
  include Admin::EmployeeNotFound

  before_action :set_employee
  before_action :set_grant

  # 削除の画面は new だけなので、URL を直接開いたとき（削除に失敗した後の再読み込みなど）は確認画面へ戻す
  def show
    redirect_to new_admin_employee_paid_leave_grant_removal_path(@employee, @grant), status: :see_other
  end

  def new
    @removal = PaidLeaveGrantRemoval.new(grant: @grant, admin: current_user)
    load_preview
  end

  def create
    @removal = PaidLeaveGrantRemoval.new(grant: @grant, admin: current_user, reason: reason_param)

    if @removal.save
      redirect_to admin_employee_paid_leave_grants_path(@employee), notice: success_message, status: :see_other
    elsif @removal.grant.removed?
      # 同時に別の管理者が削除した（二重の削除）。記録は先に削除した1件だけ
      redirect_to admin_employee_paid_leave_grants_path(@employee), alert: @removal.errors.full_messages.join(" "), status: :see_other
    else
      load_preview
      flash.now[:alert] = "付与を削除できませんでした：#{@removal.errors.full_messages.join(' ')}"
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_employee
    @employee = User.find(params[:employee_id])
  end

  # 他の従業員の付与は、この従業員の URL からは扱わない（見つからない扱い）
  def set_grant
    @grant = PaidLeaveGrant.includes(:granted_by, :removed_by).find_by(id: params[:paid_leave_grant_id], user_id: @employee.id)
    if @grant.nil?
      redirect_to admin_employee_paid_leave_grants_path(@employee), alert: "指定された付与が見つかりません。一覧から選び直してください。", status: :see_other
    elsif @grant.removed?
      redirect_to admin_employee_paid_leave_grants_path(@employee),
                  alert: "この付与はすでに削除されています（#{@grant.removed_by&.name || '—'}・#{I18n.l(@grant.removed_at, format: :short)}）。",
                  status: :see_other
    end
  end

  # 確認画面に出す、削除の影響（使用・残り・削除後の残日数・削除できない理由）
  def load_preview
    @account = PaidLeaveAccount.new(@employee)
    after_grants = @account.grants.reject { |item| item.id == @grant.id }
    @account_after = PaidLeaveAccount.new(@employee, grants: after_grants)
    @current_grant = @account.grants.find { |item| item.id == @grant.id } || @grant
    increase = @removal.shortage_increase
    @blocked_message = PaidLeaveGrantRemoval.blocked_message(increase) if increase.positive?
  end

  # パラメーターが欠けていても 400 にせず、確認画面にエラーを出す
  def reason_param
    raw = params[:paid_leave_grant_removal]
    raw.is_a?(ActionController::Parameters) ? raw[:reason].to_s : ""
  end

  def success_message
    grant = @removal.grant
    "#{I18n.l(grant.granted_on)} 付与の #{LeaveRequest.format_days(grant.granted_days)}（#{I18n.l(grant.expires_on)} まで）を削除しました。" \
      "削除の記録は、付与・取得の履歴に残ります。"
  end
end
