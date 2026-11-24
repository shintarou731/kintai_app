require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  def change_params(current: "password123", new_password: "newpassword1", confirmation: "newpassword1")
    { user: { current_password: current, password: new_password, password_confirmation: confirmation } }
  end

  test "未ログインではパスワード変更画面を開けない" do
    get edit_password_path
    assert_redirected_to login_path
  end

  test "従業員も自分のパスワードを変更でき、新しいパスワードでログインできる" do
    sign_in_as users(:employee)
    get edit_password_path
    assert_response :success
    assert_select "input[name='user[current_password]']"
    assert_select "input[name='user[password]']"
    assert_select "input[name='user[password_confirmation]']"

    patch password_path, params: change_params
    assert_redirected_to root_path
    follow_redirect!
    assert_select ".flash--notice", "パスワードを変更しました。"

    delete logout_path
    sign_in_as users(:employee), password: "newpassword1"
    assert_redirected_to root_path
  end

  test "現在のパスワードが誤っていると変更できない" do
    sign_in_as users(:admin)
    patch password_path, params: change_params(current: "wrong-password")
    assert_response :unprocessable_entity
    assert_select ".form-errors", /現在のパスワードが正しくありません/
    assert users(:admin).reload.authenticate("password123")
  end

  test "確認が一致しない・8文字未満・空欄では変更できない" do
    sign_in_as users(:employee)

    patch password_path, params: change_params(confirmation: "different1")
    assert_response :unprocessable_entity
    assert_select ".form-errors", /パスワード（確認）とパスワードの入力が一致しません/

    patch password_path, params: change_params(new_password: "short12", confirmation: "short12")
    assert_select ".form-errors", /パスワードは8文字以上で入力してください/

    patch password_path, params: change_params(new_password: "", confirmation: "")
    assert_select ".form-errors", /パスワードを入力してください/

    assert users(:employee).reload.authenticate("password123")
  end
end
