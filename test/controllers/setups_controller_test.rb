require "test_helper"

class SetupsControllerTest < ActionDispatch::IntegrationTest
  def valid_params
    { user: { name: "最初 管理者", email: "first@example.com", password: "password123", password_confirmation: "password123" } }
  end

  test "ユーザーがいないとき、トップにアクセスすると初期セットアップ画面へ移動する" do
    PaidLeaveGrant.delete_all # 付与（F10）は従業員を参照するので、先に消す
    User.delete_all
    get root_path
    assert_redirected_to setup_path

    follow_redirect!
    assert_response :success
    assert_select "h1", "初期セットアップ"
    assert_select "input[name='user[name]']"
    assert_select "input[name='user[email]']"
    assert_select "input[name='user[password]']"
    assert_select "input[name='user[password_confirmation]']"
  end

  test "ユーザーがいないとき、ログイン画面にアクセスしても初期セットアップ画面へ移動する" do
    PaidLeaveGrant.delete_all # 付与（F10）は従業員を参照するので、先に消す
    User.delete_all
    get login_path
    assert_redirected_to setup_path
  end

  test "初期セットアップを完了すると管理者としてログインしホームへ移動する" do
    PaidLeaveGrant.delete_all # 付与（F10）は従業員を参照するので、先に消す
    User.delete_all

    assert_difference -> { User.count }, 1 do
      post setup_path, params: valid_params
    end

    user = User.last
    assert user.admin?
    assert_equal "first@example.com", user.email
    assert_redirected_to root_path

    follow_redirect!
    assert_response :success
    assert_select ".header__user-name", "最初 管理者"
    assert_select ".flash--notice", /初期セットアップが完了しました/
  end

  test "role を送っても管理者として作成される（パラメータで役割を変えられない）" do
    PaidLeaveGrant.delete_all # 付与（F10）は従業員を参照するので、先に消す
    User.delete_all
    post setup_path, params: { user: valid_params[:user].merge(role: "employee") }
    assert User.last.admin?
  end

  test "パスワードが8文字未満だと作成できずエラーを表示する" do
    PaidLeaveGrant.delete_all # 付与（F10）は従業員を参照するので、先に消す
    User.delete_all

    assert_no_difference -> { User.count } do
      post setup_path, params: { user: valid_params[:user].merge(password: "short12", password_confirmation: "short12") }
    end
    assert_response :unprocessable_entity
    assert_select ".form-errors", /パスワードは8文字以上で入力してください/
  end

  test "パスワード確認が一致しないと作成できない" do
    PaidLeaveGrant.delete_all # 付与（F10）は従業員を参照するので、先に消す
    User.delete_all

    assert_no_difference -> { User.count } do
      post setup_path, params: { user: valid_params[:user].merge(password_confirmation: "password999") }
    end
    assert_response :unprocessable_entity
    assert_select ".form-errors", /パスワード（確認）とパスワードの入力が一致しません/
  end

  test "必須項目が空だと作成できない" do
    PaidLeaveGrant.delete_all # 付与（F10）は従業員を参照するので、先に消す
    User.delete_all
    post setup_path, params: { user: { name: "", email: "", password: "", password_confirmation: "" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors li", minimum: 3
  end

  test "ユーザーが存在するとき、初期セットアップ画面はログイン画面へ移動する" do
    get setup_path
    assert_redirected_to login_path
    follow_redirect!
    assert_select ".flash--alert", /初期セットアップは完了しています/
  end

  test "ログイン中に初期セットアップ画面を開くと、ログインを促さずにホームへ戻る" do
    sign_in_as users(:admin)
    get setup_path
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
    assert_select ".flash--notice", "初期セットアップは完了しています。"
    assert_select ".flash--alert", count: 0
  end

  test "ユーザーが存在するとき、初期セットアップのPOSTでは管理者を作成できない" do
    assert_no_difference -> { User.count } do
      post setup_path, params: valid_params
    end
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end
end
