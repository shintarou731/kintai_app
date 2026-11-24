require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "ログイン画面を表示できる" do
    get login_path
    assert_response :success
    assert_select "h1", "ログイン"
    assert_select ".header", count: 0
  end

  test "正しいメールアドレスとパスワードでログインできる" do
    sign_in_as users(:admin)
    assert_redirected_to root_path
    follow_redirect!
    assert_select ".header__user-name", "管理 太郎"
    assert_select ".flash--notice", "ログインしました。"
  end

  test "メールアドレスの大文字小文字や前後の空白は区別しない" do
    post login_path, params: { email: " Admin@Example.com ", password: "password123" }
    assert_redirected_to root_path
  end

  test "パスワードが誤っているとログインできず、共通のエラーを表示する" do
    sign_in_as users(:admin), password: "wrong-password"
    assert_response :unprocessable_entity
    assert_select ".flash--alert", "メールアドレスまたはパスワードが正しくありません。"
    assert_select "input[name='email'][value='admin@example.com']"
    assert_nil session[:user_id]
  end

  test "存在しないメールアドレスでも同じエラーを表示する" do
    post login_path, params: { email: "nobody@example.com", password: "password123" }
    assert_response :unprocessable_entity
    assert_select ".flash--alert", "メールアドレスまたはパスワードが正しくありません。"
  end

  test "空のまま送信してもエラーを表示する" do
    post login_path, params: { email: "", password: "" }
    assert_response :unprocessable_entity
    assert_select ".flash--alert", "メールアドレスまたはパスワードが正しくありません。"
  end

  test "無効なユーザーは正しいパスワードでもログインできず、無効である旨を表示する" do
    sign_in_as users(:inactive_employee)
    assert_response :unprocessable_entity
    assert_select ".flash--alert", /このアカウントは無効になっているため、ログインできません/
    assert_nil session[:user_id]
  end

  test "無効なユーザーでもパスワードが誤っていれば共通のエラーを表示する（状態を明かさない）" do
    sign_in_as users(:inactive_employee), password: "wrong-password"
    assert_select ".flash--alert", "メールアドレスまたはパスワードが正しくありません。"
  end

  test "ログイン済みでログイン画面にアクセスするとホームへ移動する" do
    sign_in_as users(:admin)
    get login_path
    assert_redirected_to root_path
  end

  test "ログアウトするとログイン画面に戻り、ホームにアクセスできなくなる" do
    sign_in_as users(:admin)
    delete logout_path
    assert_redirected_to login_path
    follow_redirect!
    assert_select ".flash--notice", "ログアウトしました。"

    get root_path
    assert_redirected_to login_path
  end

  test "ログイン前にアクセスしようとした画面へログイン後に戻る" do
    get root_path(foo: "bar")
    assert_redirected_to login_path
    sign_in_as users(:admin)
    assert_redirected_to root_path(foo: "bar")
  end

  test "ログイン時にセッションIDが作り直される" do
    get login_path
    old_session_id = session.id
    sign_in_as users(:admin)
    assert_not_equal old_session_id, session.id
  end
end
