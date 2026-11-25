require "test_helper"

class Admin::Employees::PasswordsControllerTest < ActionDispatch::IntegrationTest
  test "管理者は従業員のパスワードを再設定でき、新しいパスワードでログインできる" do
    sign_in_as users(:admin)
    get edit_admin_employee_password_path(users(:employee))
    assert_response :success
    assert_select "input[name='user[password]']"

    patch admin_employee_password_path(users(:employee)), params: { user: { password: "resetpass1" } }
    assert_redirected_to edit_admin_employee_path(users(:employee))
    follow_redirect!
    assert_select ".flash--notice", /パスワードを再設定しました/

    delete logout_path
    sign_in_as users(:employee), password: "password123"
    assert_response :unprocessable_entity
    sign_in_as users(:employee), password: "resetpass1"
    assert_redirected_to root_path
  end

  test "8文字未満・空欄では再設定できない" do
    sign_in_as users(:admin)
    patch admin_employee_password_path(users(:employee)), params: { user: { password: "short12" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors", /パスワードは8文字以上で入力してください/

    patch admin_employee_password_path(users(:employee)), params: { user: { password: "" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors", /パスワードを入力してください/

    assert users(:employee).reload.authenticate("password123")
  end

  test "自分自身の再設定画面は通常のパスワード変更画面へ移動する" do
    sign_in_as users(:admin)
    get edit_admin_employee_password_path(users(:admin))
    assert_redirected_to edit_password_path

    patch admin_employee_password_path(users(:admin)), params: { user: { password: "resetpass1" } }
    assert_redirected_to edit_password_path
    assert users(:admin).reload.authenticate("password123")
  end

  test "従業員は他人のパスワードを再設定できない" do
    sign_in_as users(:employee)
    patch admin_employee_password_path(users(:admin)), params: { user: { password: "hacked1234" } }
    assert_redirected_to root_path
    assert users(:admin).reload.authenticate("password123")
  end
end
