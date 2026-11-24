require "test_helper"

class Admin::WorkRuleSettingsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  def valid_params(**overrides)
    { work_rule_setting: { scheduled_work_time: "8:00", standard_break_time: "1:00", closing_day: "",
                           overtime_warning_hours: "45" }.merge(overrides) }
  end

  test "未ログインではログイン画面へ移動する" do
    get admin_work_rule_setting_path
    assert_redirected_to login_path

    patch admin_work_rule_setting_path, params: valid_params(scheduled_work_time: "7:00")
    assert_redirected_to login_path
    assert_equal 0, WorkRuleSetting.count
  end

  test "管理者は設定画面を開ける。未保存なら初期値が入力されている" do
    travel_to Time.zone.local(2026, 11, 24, 10) do
      sign_in_as users(:admin)
      get admin_work_rule_setting_path
      assert_response :success
      assert_select "h1", "勤務ルール設定"
      assert_select "input[name='work_rule_setting[scheduled_work_time]'][value='8:00']"
      assert_select "input[name='work_rule_setting[standard_break_time]'][value='1:00']"
      assert_select "select[name='work_rule_setting[closing_day]'] option[selected]", "月末"
      assert_select "select[name='work_rule_setting[closing_day]'] option", 4
      assert_select "input[name='work_rule_setting[overtime_warning_hours]'][value='45']"
      assert_select "[data-testid='settings-meta']", /まだ保存されていません/
      # 締め日ごとの月度の例（今日 11/24）
      assert_select "[data-testid='closing-day-periods'] tr[data-closing-day='end']", /2026年11月.*11\/1\(日\)〜11\/30\(月\)/m
      assert_select "[data-testid='closing-day-periods'] tr[data-closing-day='end'] .badge", "現在の設定"
      assert_select "[data-testid='closing-day-periods'] tr[data-closing-day='20']", /2026年12月度.*11\/21\(土\)〜12\/20\(日\)/m
      assert_select "[data-testid='closing-day-periods'] tr[data-closing-day='25']", /2026年11月度.*10\/26\(月\)〜11\/25\(水\)/m
    end
  end

  test "管理メニューに「設定」があり、表示中は選択状態になる" do
    sign_in_as users(:admin)
    get root_path
    assert_select "[data-testid='admin-menu'] a[href='#{admin_work_rule_setting_path}']", "設定"
    get admin_work_rule_setting_path
    assert_select "[data-testid='admin-menu'] summary.is-active", "管理"
    assert_select "[data-testid='admin-menu'] a.is-active[href='#{admin_work_rule_setting_path}'][aria-current='page']", "設定"
  end

  test "管理者は設定を保存でき、変更内容がメッセージに出る" do
    sign_in_as users(:admin)
    patch admin_work_rule_setting_path,
          params: valid_params(scheduled_work_time: "7:00", standard_break_time: "0:45", closing_day: "20",
                               overtime_warning_hours: "40")
    assert_redirected_to admin_work_rule_setting_path

    setting = WorkRuleSetting.current
    assert_equal [ 420, 45, 20, 40 ], [ setting.scheduled_work_minutes, setting.standard_break_minutes,
                                        setting.closing_day, setting.overtime_warning_hours ]
    assert_equal users(:admin), setting.updated_by

    follow_redirect!
    assert_select ".flash--notice", /勤務ルールを保存しました（1日の所定労働時間 8:00 → 7:00、標準の休憩時間 1:00 → 0:45、締め日 月末 → 20日、残業時間の警告ライン 45時間 → 40時間）/
    assert_select "input[name='work_rule_setting[scheduled_work_time]'][value='7:00']"
    assert_select "select[name='work_rule_setting[closing_day]'] option[selected]", "20日"
    assert_select "[data-testid='settings-meta']", /最終更新：.*（管理 太郎）/
    assert_select "[data-testid='closing-day-periods'] tr[data-closing-day='20'] .badge", "現在の設定"

    # 2回目の保存は同じ行を更新する（1件のまま）
    patch admin_work_rule_setting_path, params: valid_params
    assert_equal 1, WorkRuleSetting.count
    assert_equal 480, WorkRuleSetting.current.scheduled_work_minutes
    assert_nil WorkRuleSetting.current.closing_day
  end

  test "何も変えずに保存すると、変更が無い旨を出す" do
    sign_in_as users(:admin)
    patch admin_work_rule_setting_path, params: valid_params
    follow_redirect!
    assert_select ".flash--notice", "勤務ルールを保存しました（変更はありません）。"
  end

  test "不正な値は保存できず、エラーを表示して入力した値を残す" do
    WorkRuleSetting.create!(scheduled_work_time: "7:00", standard_break_time: "1:00", overtime_warning_hours: "45")
    sign_in_as users(:admin)

    patch admin_work_rule_setting_path,
          params: valid_params(scheduled_work_time: "25:00", standard_break_time: "-1:00", closing_day: "31",
                               overtime_warning_hours: "-5")
    assert_response :unprocessable_entity
    assert_select ".form-errors__title", "入力内容を確認してください（4件）"
    assert_select ".form-errors__list li", "1日の所定労働時間は 24:00 以下にしてください（24時間を超える値は設定できません）"
    assert_select ".form-errors__list li", "標準の休憩時間はマイナスにできません（0:00 以上で入力してください）"
    assert_select ".form-errors__list li", "締め日は「月末」「15日」「20日」「25日」から選んでください"
    assert_select ".form-errors__list li", "月の残業時間の警告ラインは1以上の値にしてください"
    assert_select ".field_with_errors input[name='work_rule_setting[scheduled_work_time]'][value='25:00']"
    assert_select ".field_with_errors input[name='work_rule_setting[standard_break_time]'][value='-1:00']"

    setting = WorkRuleSetting.current
    assert_equal [ 420, 60, nil, 45 ], [ setting.scheduled_work_minutes, setting.standard_break_minutes,
                                         setting.closing_day, setting.overtime_warning_hours ]
  end

  test "未保存の状態で不正な値を送っても、行は作られない" do
    sign_in_as users(:admin)
    patch admin_work_rule_setting_path, params: valid_params(scheduled_work_time: "-8:00")
    assert_response :unprocessable_entity
    assert_select ".form-errors__list li", "1日の所定労働時間はマイナスにできません（0:00 以上で入力してください）"
    assert_equal 0, WorkRuleSetting.count
  end

  test "従業員は設定画面を開けず、直接送信しても保存されない" do
    sign_in_as users(:employee)

    get admin_work_rule_setting_path
    assert_redirected_to root_path
    follow_redirect!
    assert_select ".flash--alert", "この画面を表示する権限がありません。"
    assert_select "a[href='#{admin_work_rule_setting_path}']", count: 0

    patch admin_work_rule_setting_path, params: valid_params(scheduled_work_time: "1:00", closing_day: "20")
    assert_redirected_to root_path
    put admin_work_rule_setting_path, params: valid_params(scheduled_work_time: "1:00")
    assert_redirected_to root_path
    assert_equal 0, WorkRuleSetting.count
    assert_equal 480, WorkRules.current.scheduled_work_minutes
  end

  test "設定の項目を含まないリクエストは 400 にせず、設定画面にエラーを出す" do
    sign_in_as users(:admin)
    patch admin_work_rule_setting_path
    assert_response :unprocessable_entity
    assert_select ".flash--alert", "保存する内容が送信されませんでした。入力欄に値を入れて「保存する」を押してください。"
    assert_select "h1", "勤務ルール設定"
    assert_equal 0, WorkRuleSetting.count

    patch admin_work_rule_setting_path, params: { work_rule_setting: "abc" }
    assert_response :unprocessable_entity
    assert_equal 0, WorkRuleSetting.count
  end

  test "締め日ごとの範囲の表は、スマートフォン幅では縦積みの表示になる（各欄に名前を付ける）" do
    sign_in_as users(:admin)
    get admin_work_rule_setting_path
    assert_select "[data-testid='closing-day-periods'] table.table--responsive"
    assert_select "[data-testid='closing-day-periods'] td[data-label='期間']", 4
  end
end
