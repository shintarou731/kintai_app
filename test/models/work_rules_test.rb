require "test_helper"

class WorkRulesTest < ActiveSupport::TestCase
  test "設定がまだ保存されていなければ初期値（所定 8:00・休憩 1:00・月末締め・警告ライン 45時間）" do
    assert_equal 0, WorkRuleSetting.count
    rules = WorkRules.current
    assert_equal 480, rules.scheduled_work_minutes
    assert_equal 60, rules.standard_break_minutes
    assert rules.month_end_closing?
    assert_nil rules.closing_day
    assert_equal 45, rules.overtime_warning_hours
  end

  test "保存された設定を返す" do
    WorkRuleSetting.create!(scheduled_work_time: "7:00", standard_break_time: "0:45", closing_day: "20",
                            overtime_warning_hours: "30")
    rules = WorkRules.current
    assert_equal 420, rules.scheduled_work_minutes
    assert_equal 45, rules.standard_break_minutes
    assert_equal 20, rules.closing_day
    assert_not rules.month_end_closing?
    assert_equal 30, rules.overtime_warning_hours
    assert_equal "2026-12", rules.period_containing(Date.new(2026, 11, 24)).to_param
  end

  test "残業時間が警告ラインを超えているか（ちょうどは超えていない）" do
    rules = WorkRules.new(overtime_warning_hours: 45)
    assert_not rules.overtime_warning?(45 * 60)
    assert rules.overtime_warning?((45 * 60) + 1)
  end

  test "締め日に従って月度を決める" do
    assert_equal "2026-11", WorkRules.current.period_containing(Date.new(2026, 11, 30)).to_param
    assert_equal "2026-12", WorkRules.new(closing_day: 20).period_containing(Date.new(2026, 11, 30)).to_param
    assert_equal Date.new(2026, 10, 21), WorkRules.new(closing_day: 20).period_from_param("2026-11").start_date
    assert_nil WorkRules.current.period_from_param("2026/11")
  end
end
