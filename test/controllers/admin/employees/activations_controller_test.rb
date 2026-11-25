require "test_helper"

class Admin::Employees::ActivationsControllerTest < ActionDispatch::IntegrationTest
  test "管理者は従業員を無効にでき、無効になった従業員はログインできない" do
    sign_in_as users(:admin)
    delete admin_employee_activation_path(users(:employee))
    assert_redirected_to edit_admin_employee_path(users(:employee))
    follow_redirect!
    assert_select ".flash--notice", /従業 花子 さんを無効にしました/
    assert_not users(:employee).reload.active?

    delete logout_path
    sign_in_as users(:employee)
    assert_response :unprocessable_entity
    assert_select ".flash--alert", /このアカウントは無効になっているため、ログインできません/
    assert_nil session[:user_id]
  end

  test "無効から有効に戻すと再びログインできる" do
    sign_in_as users(:admin)
    post admin_employee_activation_path(users(:inactive_employee))
    assert_redirected_to edit_admin_employee_path(users(:inactive_employee))
    assert users(:inactive_employee).reload.active?

    delete logout_path
    sign_in_as users(:inactive_employee)
    assert_redirected_to root_path
  end

  test "自分自身は無効にできない" do
    admin = users(:admin)
    sign_in_as admin
    delete admin_employee_activation_path(admin)
    assert_redirected_to edit_admin_employee_path(admin)
    follow_redirect!
    assert_select ".flash--alert", /自分自身を無効にすることはできません/
    assert admin.reload.active?
  end

  test "従業員は無効化・有効化の操作ができない" do
    sign_in_as users(:employee)
    delete admin_employee_activation_path(users(:admin))
    assert_redirected_to root_path
    assert users(:admin).reload.active?

    post admin_employee_activation_path(users(:inactive_employee))
    assert_redirected_to root_path
    assert_not users(:inactive_employee).reload.active?
  end

  test "ログイン中に無効化されたユーザーは次の操作でログアウトされる" do
    sign_in_as users(:employee)
    get root_path
    assert_response :success

    users(:employee).update!(active: false)

    get root_path
    assert_redirected_to login_path
    follow_redirect!
    assert_select ".flash--alert", /このアカウントは無効になっているため/
    assert_nil session[:user_id]
  end
end
