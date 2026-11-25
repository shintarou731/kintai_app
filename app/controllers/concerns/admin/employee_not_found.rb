# 存在しない従業員 ID（例：/admin/employees/9999/edit）にアクセスされたとき、
# 例外画面ではなく従業員一覧に戻して知らせる
module Admin::EmployeeNotFound
  extend ActiveSupport::Concern

  NOT_FOUND_MESSAGE = "指定された従業員が見つかりません。一覧から選び直してください。".freeze

  included do
    rescue_from ActiveRecord::RecordNotFound, with: :redirect_employee_not_found
  end

  private

  def redirect_employee_not_found
    redirect_to admin_employees_path, alert: NOT_FOUND_MESSAGE, status: :see_other
  end
end
