require "test_helper"

# 勤務ルール設定（F6）が勤怠履歴に反映されること
class AttendancesWorkRulesTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:employee)
  end

  def t(day, hour, min = 0, month: 11)
    Time.zone.local(2026, month, day, hour, min)
  end

  def work(clock_in, clock_out, breaks: [])
    record = @user.attendances.create!(work_date: clock_in.to_date, clock_in_at: clock_in, clock_out_at: clock_out)
    breaks.each { |from, to| record.breaks.create!(started_at: from, ended_at: to) }
    record
  end

  def row(date)
    "tr[data-date='#{date.iso8601}']"
  end

  def save_rules(**attributes)
    WorkRuleSetting.create!({ scheduled_work_time: "8:00", standard_break_time: "1:00", closing_day: "",
                              overtime_warning_hours: "45" }.merge(attributes))
  end

  # 管理者が画面から設定を保存する
  def save_rules_as_admin(**attributes)
    delete logout_path
    sign_in_as users(:admin)
    patch admin_work_rule_setting_path,
          params: { work_rule_setting: { scheduled_work_time: "8:00", standard_break_time: "1:00", closing_day: "",
                                         overtime_warning_hours: "45" }.merge(attributes) }
    assert_redirected_to admin_work_rule_setting_path
    delete logout_path
  end

  test "設定が保存されていなければ初期値（所定 8:00・月末締め）で計算する" do
    work(t(2, 9), t(2, 18)) # 実働 9:00
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='period-label']", /2026年11月/
      assert_select "[data-testid='period-range']", "11/1(日)〜11/30(月)"
      assert_select "[data-testid='closing-day']", "（月末締め）"
      assert_select "#{row(Date.new(2026, 11, 2))} td[data-column='overtime']", "1:00"
      assert_select "[data-testid='monthly-totals']", /所定労働時間（8:00）/
      assert_select "[data-testid='overtime-warning']", "警告ライン 45時間"
    end
  end

  test "所定労働時間を 7:00 にすると、実働 8:00 の日の残業は 1:00 になる" do
    work(t(2, 9), t(2, 18), breaks: [ [ t(2, 12), t(2, 13) ] ]) # 実働 8:00
    work(t(3, 9), t(3, 16, 30))                                  # 実働 7:30
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "#{row(Date.new(2026, 11, 2))} td[data-column='overtime']", "0:00"
      assert_select "[data-testid='total-overtime']", "0:00"

      save_rules_as_admin(scheduled_work_time: "7:00")

      sign_in_as @user
      get attendances_path
      assert_select "#{row(Date.new(2026, 11, 2))} td[data-column='worked']", "8:00"
      assert_select "#{row(Date.new(2026, 11, 2))} td[data-column='overtime']", "1:00"
      assert_select "#{row(Date.new(2026, 11, 3))} td[data-column='overtime']", "0:30"
      assert_select "[data-testid='total-overtime']", "1:30"
      assert_select "[data-testid='monthly-totals']", /所定労働時間（7:00）/
    end
  end

  test "20日締めでは、初期表示は今日が属する月度（11/24 は12月度＝11/21〜12/20）" do
    save_rules(closing_day: "20")
    work(t(21, 9), t(21, 17))
    work(t(20, 9), t(20, 17))
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='period-label']", /2026年12月度/
      assert_select "[data-testid='period-label'] .badge", "今月度"
      assert_select "[data-testid='period-range']", "11/21(土)〜12/20(日)"
      assert_select "[data-testid='closing-day']", "（20日締め）"
      assert_select "[data-testid='attendance-days'] tbody tr", 30
      assert_select "[data-testid='attendance-days'] tbody tr:first-child[data-date='2026-11-21']"
      assert_select "[data-testid='attendance-days'] tbody tr:last-child[data-date='2026-12-20']"
      assert_select row(Date.new(2026, 11, 20)), 0 # 11/20 は11月度
      assert_select "[data-testid='total-days']", "1日"
      assert_select "#totals-title", "この月度の合計"
      assert_select "a[data-testid='previous-month'][href=?]", attendances_path(month: "2026-11"), text: "← 前月度"
      assert_select "a[data-testid='next-month'][href=?]", attendances_path(month: "2027-01"), text: "翌月度 →"
      assert_select "[data-testid='current-month']", 0
    end
  end

  test "20日締めの11月度は 10/21〜11/20（10/20 と 11/21 は含まない）" do
    save_rules(closing_day: "20")
    work(t(20, 9, month: 10), t(20, 18, month: 10)) # 10月度
    work(t(21, 9, month: 10), t(21, 18, month: 10)) # 11月度の初日
    work(t(20, 9), t(20, 18))                       # 11月度の最終日
    work(t(21, 9), t(21, 18))                       # 12月度
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path(month: "2026-11")
      assert_select "[data-testid='period-label']", "2026年11月度"
      assert_select "[data-testid='period-range']", "10/21(水)〜11/20(金)"
      assert_select "[data-testid='attendance-days'] tbody tr", 31
      assert_select row(Date.new(2026, 10, 20)), 0
      assert_select row(Date.new(2026, 10, 21))
      assert_select row(Date.new(2026, 11, 20))
      assert_select row(Date.new(2026, 11, 21)), 0
      assert_select "[data-testid='total-days']", "2日"
      assert_select "[data-testid='total-worked']", "18:00"
      assert_select "a[data-testid='current-month'][href='#{attendances_path}']", "今月度"
      assert_select "a[data-testid='previous-month'][href=?]", attendances_path(month: "2026-10")

      get attendances_path(month: "2026-10")
      assert_select "[data-testid='period-range']", "9/21(月)〜10/20(火)"
      assert_select "[data-testid='total-days']", "1日"
    end
  end

  test "15日締め：11/15 は11月度、11/16 は12月度。2月度は 1/16〜2/15" do
    save_rules(closing_day: "15")
    travel_to t(15, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='period-label']", /2026年11月度/
      assert_select "[data-testid='period-range']", "10/16(金)〜11/15(日)"
    end
    travel_to t(16, 10) do
      get attendances_path
      assert_select "[data-testid='period-label']", /2026年12月度/
      assert_select "[data-testid='period-range']", "11/16(月)〜12/15(火)"

      get attendances_path(month: "2027-02")
      assert_select "[data-testid='period-range']", "1/16(土)〜2/15(月)"
      assert_select "[data-testid='attendance-days'] tbody tr", 31
      get attendances_path(month: "2027-03")
      assert_select "[data-testid='period-range']", "2/16(火)〜3/15(月)"
      assert_select "[data-testid='attendance-days'] tbody tr", 28
    end
  end

  test "月末締めに戻すと、1日〜末日の表示に戻る" do
    setting = save_rules(closing_day: "20")
    setting.update!(closing_day: "")
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path(month: "2027-02")
      assert_select "[data-testid='period-label']", "2027年2月"
      assert_select "[data-testid='period-range']", "2/1(月)〜2/28(日)"
      assert_select "a[data-testid='current-month']", "今月"
    end
  end

  test "ホームの退勤漏れのリンクは、締め日に従ってその勤務日が属する月度を開く" do
    save_rules(closing_day: "20")
    @user.attendances.create!(work_date: Date.new(2026, 11, 21), clock_in_at: t(21, 9)) # 12月度の退勤漏れ
    travel_to t(24, 10) do
      sign_in_as @user
      get root_path
      assert_select "[data-testid='missing-clock-outs-history-link'][href=?]", attendances_path(month: "2026-12")
    end
  end

  test "月の残業時間が警告ラインを超えると、総残業時間の下に赤い注意を出す（ちょうどは出さない）" do
    save_rules(scheduled_work_time: "1:00", overtime_warning_hours: "7")
    work(t(2, 9), t(2, 17)) # 実働 8:00 → 残業 7:00
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='total-overtime']", "7:00"
      assert_select "[data-testid='overtime-warning']:not(.summary__caption--danger)", "警告ライン 7時間"

      work(t(3, 9), t(3, 10, 1)) # 実働 1:01 → 残業 0:01
      get attendances_path
      assert_select "[data-testid='total-overtime']", "7:01"
      assert_select "[data-testid='overtime-warning'].summary__caption--danger", "警告ライン（7時間）を超えています"
    end
  end
end
