require "test_helper"
require "minitest/mock"

class UserTest < ActiveSupport::TestCase
  def build_user(**attrs)
    User.new({ name: "山田 一郎", email: "ichiro@example.com", password: "password123", password_confirmation: "password123" }.merge(attrs))
  end

  test "有効な属性なら保存できる" do
    assert build_user.save
  end

  test "役割の初期値は従業員" do
    assert build_user.employee?
  end

  test "パスワードは8文字以上が必要" do
    user = build_user(password: "short12", password_confirmation: "short12")
    assert_not user.valid?
    assert_includes user.errors[:password], "は8文字以上で入力してください"

    assert build_user(password: "exactly8", password_confirmation: "exactly8").valid?
  end

  test "パスワード確認が一致しないと保存できない" do
    user = build_user(password_confirmation: "different1")
    assert_not user.valid?
    assert user.errors[:password_confirmation].any?
  end

  test "氏名・メールアドレス・パスワードは必須" do
    user = User.new
    assert_not user.valid?
    assert user.errors[:name].any?
    assert user.errors[:email].any?
    assert user.errors[:password].any?
  end

  test "メールアドレスの形式が不正なら保存できない" do
    assert_not build_user(email: "not-an-email").valid?
  end

  test "メールアドレスは前後の空白を除き小文字に正規化され、重複できない" do
    user = build_user(email: "  Ichiro@Example.COM ")
    user.save!
    assert_equal "ichiro@example.com", user.email

    duplicate = build_user(email: "ICHIRO@example.com")
    assert_not duplicate.valid?
    assert duplicate.errors[:email].any?
  end

  test "役割の表示名" do
    assert_equal "管理者", users(:admin).role_label
    assert_equal "従業員", users(:employee).role_label
  end

  test "setup_required? はユーザーがいないときだけ true" do
    assert_not User.setup_required?
    PaidLeaveGrant.delete_all # 付与（F10）は従業員を参照するので、先に消す
    User.delete_all
    assert User.setup_required?
  end

  test "既定値は雇用区分＝正社員、状態＝有効" do
    user = build_user
    assert user.full_time?
    assert user.active?
  end

  test "雇用区分・状態の表示名" do
    assert_equal "パート・アルバイト", users(:employee).employment_type_label
    assert_equal "正社員", users(:admin).employment_type_label
    assert_equal "有効", users(:admin).status_label
    assert_equal "無効", users(:inactive_employee).status_label
  end

  test "不正な雇用区分は保存できない" do
    assert_not build_user(employment_type: "contract").valid?
  end

  test "入社日は従業員管理フォームのときだけ必須" do
    user = build_user(hired_on: nil)
    assert user.valid?
    assert_not user.valid?(User::STAFF_FORM_CONTEXT)
    assert_includes user.errors[:hired_on], "を入力してください"
  end

  test "自分自身の役割を従業員に変更できない" do
    admin = users(:admin)
    admin.editor = admin
    admin.role = :employee
    assert_not admin.save
    assert_includes admin.errors.full_messages, "役割は自分自身では従業員に変更できません"
  end

  test "自分自身を無効にできない" do
    admin = users(:admin)
    admin.editor = admin
    assert_not admin.deactivate
    assert_includes admin.errors.full_messages, "自分自身を無効にすることはできません"
    assert admin.reload.active?
  end

  test "最後の有効な管理者を従業員に変更・無効化できない" do
    admin = users(:admin)
    assert_not admin.update(role: :employee)
    assert_includes admin.errors.full_messages, "有効な管理者が1人もいなくなるため、この変更はできません"
    assert_not admin.reload.deactivate
  end

  test "他に有効な管理者がいれば、管理者を従業員に変更・無効化できる" do
    users(:employee).update!(role: :admin)
    admin = users(:admin)
    admin.editor = users(:employee)
    assert admin.update(role: :employee)
    assert admin.deactivate
  end

  test "同時操作で保存前の確認をすり抜けても、有効な管理者が0人になる変更は取り消される" do
    users(:employee).update!(role: :admin)
    other_admin = users(:employee)
    admin = users(:admin)
    admin.editor = other_admin

    # もう一方の管理者が同時に無効化された（この操作の確認より後に確定した）状況を作る
    other_admin.update_columns(active: false)
    admin.stub(:keep_at_least_one_active_admin, nil) do
      assert_not admin.deactivate
    end
    assert_includes admin.errors.full_messages, "有効な管理者が1人もいなくなるため、この変更はできません"
    assert admin.reload.active?

    admin.editor = other_admin
    admin.role = :employee
    admin.stub(:keep_at_least_one_active_admin, nil) do
      assert_not admin.save_keeping_active_admin
    end
    assert admin.reload.admin?
    assert_equal [ admin ], User.active_admins.to_a
  end

  test "save_keeping_active_admin は通常の変更なら保存する" do
    user = users(:employee)
    user.name = "従業 花子２"
    assert user.save_keeping_active_admin(context: User::STAFF_FORM_CONTEXT)
    assert_equal "従業 花子２", user.reload.name
  end

  test "無効な管理者は「有効な管理者」の人数に数えない" do
    users(:inactive_employee).update!(role: :admin)
    assert_equal [ users(:admin) ], User.active_admins.to_a
    assert_not users(:admin).update(role: :employee)
  end

  test "change_password は現在のパスワードが正しいときだけ変更する" do
    user = users(:employee)
    assert_not user.change_password(current_password: "wrong", new_password: "newpassword1", new_password_confirmation: "newpassword1")
    assert_includes user.errors.full_messages, "現在のパスワードが正しくありません"

    user = users(:employee).reload
    assert_not user.change_password(current_password: "password123", new_password: "newpassword1", new_password_confirmation: "different1")
    assert user.errors[:password_confirmation].any?

    user = users(:employee).reload
    assert_not user.change_password(current_password: "password123", new_password: "", new_password_confirmation: "")
    assert_includes user.errors.full_messages, "パスワードを入力してください"

    user = users(:employee).reload
    assert user.change_password(current_password: "password123", new_password: "newpassword1", new_password_confirmation: "newpassword1")
    assert user.reload.authenticate("newpassword1")
  end

  test "reset_password は8文字未満を受け付けない" do
    user = users(:employee)
    assert_not user.reset_password("short12")
    assert_includes user.errors.full_messages, "パスワードは8文字以上で入力してください"
    assert user.reset_password("resetpass1")
    assert user.reload.authenticate("resetpass1")
  end

  test "authenticate_by_credentials は正しい組み合わせのときだけユーザーを返す" do
    assert_equal users(:admin), User.authenticate_by_credentials(" ADMIN@example.com ", "password123")
    assert_nil User.authenticate_by_credentials("admin@example.com", "wrong-password")
    assert_nil User.authenticate_by_credentials("nobody@example.com", "password123")
    assert_nil User.authenticate_by_credentials("", "")
    assert_nil User.authenticate_by_credentials(nil, nil)
  end

  test "氏名に改行・タブなどの制御文字は使えない（前後の空白・改行は取り除く）" do
    [ "山田\n太郎", "山田\r太郎", "山田\t太郎", "山田\u0000太郎", "山田 太郎" ].each do |name|
      user = User.new(name: name, email: "ctrl@example.com", password: "password123")
      assert_not user.valid?, name.inspect
      assert_includes user.errors.full_messages, "氏名に改行・タブなどの制御文字は使えません"
    end
    user = User.new(name: "  山田 太郎\n", email: "ctrl@example.com", password: "password123")
    assert user.valid?, user.errors.full_messages.inspect
    assert_equal "山田 太郎", user.name
    assert User.new(name: "山田　太郎", email: "ctrl@example.com", password: "password123").valid?, "全角の空白は使える"
  end
end
