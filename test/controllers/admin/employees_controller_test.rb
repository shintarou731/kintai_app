require "test_helper"

class Admin::EmployeesControllerTest < ActionDispatch::IntegrationTest
  def valid_params(**overrides)
    { user: { name: "新人 三郎", email: "saburo@example.com", password: "initial123",
              role: "employee", employment_type: "part_time", hired_on: "2026-11-01" }.merge(overrides) }
  end

  test "未ログインでは従業員一覧を開けずログイン画面へ" do
    get admin_employees_path
    assert_redirected_to login_path
  end

  test "管理者は従業員一覧で氏名・メール・役割・雇用区分・状態を見られる" do
    sign_in_as users(:admin)
    get admin_employees_path
    assert_response :success

    assert_select "th", "氏名"
    assert_select "th", "メールアドレス"
    assert_select "th", "役割"
    assert_select "th", "雇用区分"
    assert_select "th", "状態"
    assert_select "#user_#{users(:employee).id}" do
      assert_select "td", /従業 花子/
      assert_select "td", "hanako@example.com"
      assert_select "td", "従業員"
      assert_select "td", "パート・アルバイト"
      assert_select "td", "有効"
    end
    assert_select "#user_#{users(:inactive_employee).id}.is-inactive td", "無効"
    assert_select "#user_#{users(:admin).id} .badge", "あなた"
  end

  test "状態で絞り込める" do
    sign_in_as users(:admin)

    get admin_employees_path(status: "inactive")
    assert_select "tbody tr", 1
    assert_select "tbody tr td", /退職 次郎/

    get admin_employees_path(status: "active")
    assert_select "tbody tr", 2

    get admin_employees_path(status: "unknown")
    assert_select "tbody tr", 3
  end

  test "管理者は従業員を追加でき、追加された従業員はログインできる" do
    sign_in_as users(:admin)
    get new_admin_employee_path
    assert_response :success
    %w[name email password role employment_type hired_on].each do |field|
      assert_select "[name='user[#{field}]']"
    end

    assert_difference -> { User.count }, 1 do
      post admin_employees_path, params: valid_params
    end
    assert_redirected_to admin_employees_path
    follow_redirect!
    assert_select ".flash--notice", /新人 三郎 さんを登録しました/

    user = User.find_by!(email: "saburo@example.com")
    assert user.employee?
    assert user.part_time?
    assert user.active?
    assert_equal Date.new(2026, 11, 1), user.hired_on

    delete logout_path
    post login_path, params: { email: "saburo@example.com", password: "initial123" }
    assert_redirected_to root_path
  end

  test "管理者として追加することもできる" do
    sign_in_as users(:admin)
    post admin_employees_path, params: valid_params(role: "admin", employment_type: "full_time")
    user = User.find_by!(email: "saburo@example.com")
    assert user.admin?
    assert user.full_time?
  end

  test "登録済みのメールアドレスでは追加できない" do
    sign_in_as users(:admin)
    assert_no_difference -> { User.count } do
      post admin_employees_path, params: valid_params(email: "HANAKO@example.com")
    end
    assert_response :unprocessable_entity
    assert_select ".form-errors", /メールアドレスはすでに登録されています/
  end

  test "必須項目が空だと追加できない" do
    sign_in_as users(:admin)
    assert_no_difference -> { User.count } do
      post admin_employees_path, params: { user: { name: "", email: "", password: "", role: "employee",
                                                   employment_type: "full_time", hired_on: "" } }
    end
    assert_response :unprocessable_entity
    assert_select ".form-errors li", /氏名を入力してください/
    assert_select ".form-errors li", /メールアドレスを入力してください/
    assert_select ".form-errors li", /パスワードを入力してください/
    assert_select ".form-errors li", /入社日を入力してください/
  end

  test "初期パスワードが8文字未満だと追加できない" do
    sign_in_as users(:admin)
    assert_no_difference -> { User.count } do
      post admin_employees_path, params: valid_params(password: "short12")
    end
    assert_select ".form-errors", /パスワードは8文字以上で入力してください/
  end

  test "不正な役割・雇用区分では追加できない" do
    sign_in_as users(:admin)
    assert_no_difference -> { User.count } do
      post admin_employees_path, params: valid_params(role: "owner", employment_type: "contract")
    end
    assert_response :unprocessable_entity
  end

  test "管理者は従業員の情報（役割を含む）を編集できる" do
    sign_in_as users(:admin)
    employee = users(:employee)

    get edit_admin_employee_path(employee)
    assert_response :success
    assert_select "input[name='user[name]'][value='従業 花子']"
    assert_select "[name='user[password]']", count: 0

    patch admin_employee_path(employee), params: { user: { name: "従業 華子", email: "hanako2@example.com", role: "admin",
                                                           employment_type: "full_time", hired_on: "2025-01-15" } }
    assert_redirected_to admin_employees_path
    employee.reload
    assert_equal "従業 華子", employee.name
    assert_equal "hanako2@example.com", employee.email
    assert employee.admin?
    assert employee.full_time?
    assert_equal Date.new(2025, 1, 15), employee.hired_on
  end

  test "編集時も重複メール・空欄はエラーになる" do
    sign_in_as users(:admin)
    patch admin_employee_path(users(:employee)), params: { user: { name: "", email: "admin@example.com" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors li", /氏名を入力してください/
    assert_select ".form-errors li", /メールアドレスはすでに登録されています/
    assert_equal "従業 花子", users(:employee).reload.name
  end

  test "自分の役割を従業員に変更できない（画面では選択欄が無効、送信してもエラー）" do
    admin = users(:admin)
    sign_in_as admin

    get edit_admin_employee_path(admin)
    assert_select "select[name='user[role]'][disabled]"
    assert_select "[data-testid='activation-card'] button", count: 0
    assert_select "[data-testid='activation-card']", /ご自身のアカウントは無効にできません/

    patch admin_employee_path(admin), params: { user: { role: "employee" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors", /役割は自分自身では従業員に変更できません/
    assert admin.reload.admin?
  end

  test "自分の氏名などは編集できる（入社日が未設定の既存管理者は入力が必要）" do
    admin = users(:admin)
    admin.update_columns(hired_on: nil)
    sign_in_as admin

    patch admin_employee_path(admin), params: { user: { name: "管理 太郎2" } }
    assert_response :unprocessable_entity
    assert_select ".form-errors", /入社日を入力してください/

    patch admin_employee_path(admin), params: { user: { name: "管理 太郎2", hired_on: "2020-04-01" } }
    assert_redirected_to admin_employees_path
    assert_equal "管理 太郎2", admin.reload.name
  end

  test "存在しない従業員は一覧に戻して「見つかりません」と知らせる" do
    sign_in_as users(:admin)
    missing_id = User.maximum(:id) + 1000

    [
      -> { get edit_admin_employee_path(id: missing_id) },
      -> { patch admin_employee_path(id: missing_id), params: { user: { name: "x" } } },
      -> { get edit_admin_employee_password_path(employee_id: missing_id) },
      -> { patch admin_employee_password_path(employee_id: missing_id), params: { user: { password: "password999" } } },
      -> { post admin_employee_activation_path(employee_id: missing_id) },
      -> { delete admin_employee_activation_path(employee_id: missing_id) }
    ].each do |request|
      request.call
      assert_redirected_to admin_employees_path
      follow_redirect!
      assert_select ".flash--alert", "指定された従業員が見つかりません。一覧から選び直してください。"
    end
  end

  test "従業員が存在しない ID の管理画面を開いても、権限なしとして扱う" do
    sign_in_as users(:employee)
    get edit_admin_employee_path(id: User.maximum(:id) + 1000)
    assert_redirected_to root_path
  end

  test "フォームの値を直接送っても、氏名に改行は保存できない" do
    sign_in_as users(:admin)
    employee = users(:employee)
    patch admin_employee_path(employee), params: { user: { name: "従業\n花子", email: employee.email, hired_on: "2024-10-01" } }
    assert_response :unprocessable_entity
    assert_equal "従業 花子", employee.reload.name
    assert_includes response.body, "氏名に改行・タブなどの制御文字は使えません"
  end

  test "アカウント情報から自分の編集画面を開くと、戻る・キャンセル・保存後の移り先がアカウント情報になる" do
    admin = users(:admin)
    sign_in_as admin
    get edit_admin_employee_path(admin, from: "account")
    assert_response :success
    assert_select "a.back-link[href='#{account_path}']", "← アカウント情報に戻る"
    assert_select ".form__actions a[href='#{account_path}']", "キャンセル"
    assert_select "form[action='#{admin_employee_path(admin, from: 'account')}']"
    assert_select "a[href='#{admin_employees_path}']", text: /従業員一覧に戻る|キャンセル/, count: 0

    # 入力に誤りがあって画面を出し直しても、戻り先は変わらない
    patch admin_employee_path(admin, from: "account"), params: { user: { name: "" } }
    assert_response :unprocessable_entity
    assert_select "a.back-link[href='#{account_path}']"
    assert_select "form[action='#{admin_employee_path(admin, from: 'account')}']"

    patch admin_employee_path(admin, from: "account"), params: { user: { name: "管理 太郎2" } }
    assert_redirected_to account_path
    assert_equal "管理 太郎2", admin.reload.name
  end

  test "戻り先は決まった値（from=account）の本人の編集画面だけで変わり、URL を渡しても外へは飛ばない" do
    admin = users(:admin)
    employee = users(:employee)
    sign_in_as admin

    # 他人の編集画面では from=account を無視する
    get edit_admin_employee_path(employee, from: "account")
    assert_select "a.back-link[href='#{admin_employees_path}']", "← 従業員一覧に戻る"
    assert_select ".form__actions a[href='#{admin_employees_path}']", "キャンセル"
    patch admin_employee_path(employee, from: "account"), params: { user: { name: "従業 花子2" } }
    assert_redirected_to admin_employees_path

    # 決まった値以外（外部の URL など）は無視し、従業員一覧に戻す
    [ "https://evil.example.com/", "//evil.example.com", "/account", "Account" ].each do |value|
      get edit_admin_employee_path(admin, from: value, return_to: "https://evil.example.com/")
      assert_select "a.back-link[href='#{admin_employees_path}']"
      assert_no_match(/evil\.example\.com/, response.body)
      patch admin_employee_path(admin, from: value, return_to: "https://evil.example.com/"), params: { user: { name: "管理 太郎" } }
      assert_redirected_to admin_employees_path
    end

    # from を付けないときは、これまでどおり従業員一覧へ
    get edit_admin_employee_path(admin)
    assert_select "a.back-link[href='#{admin_employees_path}']", "← 従業員一覧に戻る"
  end
end
