require "test_helper"

# 役割による画面の出し分け・アクセス制御
class AuthorizationTest < ActionDispatch::IntegrationTest
  test "従業員には管理メニューが表示されない" do
    sign_in_as users(:employee)
    get root_path
    assert_select ".header__nav a", "ホーム"
    assert_select "[data-testid='admin-menu']", count: 0
    assert_select "a[href='#{admin_employees_path}']", count: 0
  end

  test "管理者には管理メニュー（従業員）が表示される" do
    sign_in_as users(:admin)
    get root_path
    assert_select "[data-testid='admin-menu'] summary", "管理"
    assert_select "[data-testid='admin-menu'] a[href='#{admin_employees_path}']", "従業員"
  end

  test "従業員が管理画面のURLに直接アクセスするとホームに戻され、権限がない旨が表示される" do
    sign_in_as users(:employee)

    [
      admin_employees_path,
      new_admin_employee_path,
      edit_admin_employee_path(users(:admin)),
      edit_admin_employee_password_path(users(:admin))
    ].each do |path|
      get path
      assert_redirected_to root_path, "#{path} は拒否されるべき"
    end

    follow_redirect!
    assert_select ".flash--alert", "この画面を表示する権限がありません。"
  end

  test "従業員は従業員の追加・更新をできない" do
    sign_in_as users(:employee)

    assert_no_difference -> { User.count } do
      post admin_employees_path, params: { user: { name: "侵入", email: "x@example.com", password: "password123",
                                                   role: "admin", employment_type: "full_time", hired_on: "2026-01-01" } }
    end
    assert_redirected_to root_path

    patch admin_employee_path(users(:employee)), params: { user: { role: "admin" } }
    assert_redirected_to root_path
    assert users(:employee).reload.employee?
  end

  test "管理者から従業員に変更されたユーザーは、次のアクセスから管理画面に入れない" do
    users(:employee).update!(role: :admin)
    sign_in_as users(:employee)
    get admin_employees_path
    assert_response :success

    users(:employee).update!(role: :employee)
    get admin_employees_path
    assert_redirected_to root_path
  end
end
