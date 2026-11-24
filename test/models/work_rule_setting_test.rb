require "test_helper"

class WorkRuleSettingTest < ActiveSupport::TestCase
  def build(**attributes)
    WorkRuleSetting.new({ scheduled_work_time: "8:00", standard_break_time: "1:00", closing_day: "",
                          overtime_warning_hours: "45" }.merge(attributes))
  end

  def error_messages(setting, attribute)
    setting.validate
    setting.errors.full_messages_for(attribute)
  end

  test "まだ保存されていないときは初期値（所定 8:00・休憩 1:00・月末締め・警告ライン 45時間）" do
    assert_equal 0, WorkRuleSetting.count
    setting = WorkRuleSetting.current
    assert setting.new_record?
    assert_equal 480, setting.scheduled_work_minutes
    assert_equal 60, setting.standard_break_minutes
    assert_nil setting.closing_day
    assert_equal 45, setting.overtime_warning_hours
    assert_equal "8:00", setting.scheduled_work_time
    assert_equal "1:00", setting.standard_break_time
    assert_equal "月末", setting.closing_day_label
    assert setting.valid?
  end

  test "初期値は WorkRules の初期値と DB の列の既定値にそろっている" do
    defaults = WorkRuleSetting.column_defaults
    assert_equal WorkRules::DEFAULT_SCHEDULED_WORK_MINUTES, defaults["scheduled_work_minutes"]
    assert_equal WorkRules::DEFAULT_STANDARD_BREAK_MINUTES, defaults["standard_break_minutes"]
    assert_equal WorkRules::DEFAULT_OVERTIME_WARNING_HOURS, defaults["overtime_warning_hours"]
    assert_nil defaults["closing_day"]
  end

  test "保存した設定を current で読み込み、WorkRules に変換する" do
    build(scheduled_work_time: "7:30", standard_break_time: "0:45", closing_day: "20", overtime_warning_hours: "30").save!
    rules = WorkRuleSetting.current.to_work_rules
    assert_equal 450, rules.scheduled_work_minutes
    assert_equal 45, rules.standard_break_minutes
    assert_equal 20, rules.closing_day
    assert_equal 30, rules.overtime_warning_hours
  end

  test "設定は1件だけ（2件目は一意制約で保存できない）" do
    build.save!
    assert_raises(ActiveRecord::RecordNotUnique) { build.save! }
  end

  # --- 時:分の入力 ---

  test "時:分の文字列を分に直す" do
    {
      "8:00" => 480, "08:00" => 480, "7:30" => 450, "8" => 480, "0:01" => 1, "24:00" => 1440,
      " 7:45 " => 465, "８：００" => 480, "25:00" => 1500
    }.each do |input, minutes|
      assert_equal minutes, WorkRuleSetting.parse_duration(input), input.inspect
    end
    [ "", nil, "-1:00", "8:60", "8:5", "abc", "8.5", "8:00:00", ":30", "1:-1" ].each do |input|
      assert_nil WorkRuleSetting.parse_duration(input), input.inspect
    end
  end

  test "所定労働時間：0:01〜24:00 を保存できる" do
    [ "0:01", "7:00", "8:00", "23:59", "24:00", "８：００" ].each do |input|
      assert build(scheduled_work_time: input).valid?, input
    end
  end

  test "所定労働時間：負の時間・24時間を超える時間・0:00・形式の誤り・空欄は保存できない" do
    {
      "-1:00" => "1日の所定労働時間はマイナスにできません（0:00 以上で入力してください）",
      "−8:00" => "1日の所定労働時間はマイナスにできません（0:00 以上で入力してください）",
      "24:01" => "1日の所定労働時間は 24:00 以下にしてください（24時間を超える値は設定できません）",
      "25:00" => "1日の所定労働時間は 24:00 以下にしてください（24時間を超える値は設定できません）",
      "0:00" => "1日の所定労働時間は 0:00 より長くしてください",
      "8:60" => "1日の所定労働時間は「8:00」のように 時:分 で入力してください（分は 00〜59）",
      "abc" => "1日の所定労働時間は「8:00」のように 時:分 で入力してください（分は 00〜59）",
      "" => "1日の所定労働時間を入力してください"
    }.each do |input, message|
      setting = build(scheduled_work_time: input)
      assert_equal [ message ], error_messages(setting, :scheduled_work_time), input.inspect
      assert_not setting.save
    end
  end

  test "エラーのときは入力した値をそのまま返す（入力欄に残す）" do
    setting = build(scheduled_work_time: "-1:00")
    setting.validate
    assert_equal "-1:00", setting.scheduled_work_time
  end

  test "標準の休憩時間：0:00〜24:00。負の時間・24時間超・形式の誤りは保存できない" do
    [ "0:00", "1:00", "0:45", "24:00" ].each { |input| assert build(standard_break_time: input).valid?, input }

    assert_equal [ "標準の休憩時間はマイナスにできません（0:00 以上で入力してください）" ],
                 error_messages(build(standard_break_time: "-0:30"), :standard_break_time)
    assert_equal [ "標準の休憩時間は 24:00 以下にしてください（24時間を超える値は設定できません）" ],
                 error_messages(build(standard_break_time: "24:30"), :standard_break_time)
    assert_equal [ "標準の休憩時間は「8:00」のように 時:分 で入力してください（分は 00〜59）" ],
                 error_messages(build(standard_break_time: "1時間"), :standard_break_time)
  end

  test "締め日：月末（空）・15日・20日・25日だけを保存できる" do
    [ "", "15", "20", "25" ].each { |input| assert build(closing_day: input).valid?, input.inspect }
    [ "10", "31", "0", "abc", "20.0", "-20" ].each do |input|
      assert_equal [ "締め日は「月末」「15日」「20日」「25日」から選んでください" ],
                   error_messages(build(closing_day: input), :closing_day), input.inspect
    end
  end

  test "警告ライン：1〜744 の整数だけ保存できる" do
    [ "1", "45", "744" ].each { |input| assert build(overtime_warning_hours: input).valid?, input }
    {
      "0" => "月の残業時間の警告ラインは1以上の値にしてください",
      "-5" => "月の残業時間の警告ラインは1以上の値にしてください",
      "745" => "月の残業時間の警告ラインは744以下の値にしてください",
      "45.5" => "月の残業時間の警告ラインは整数で入力してください",
      "abc" => "月の残業時間の警告ラインは数値で入力してください",
      "" => "月の残業時間の警告ラインは数値で入力してください"
    }.each do |input, message|
      assert_equal [ message ], error_messages(build(overtime_warning_hours: input), :overtime_warning_hours), input.inspect
    end
  end

  test "保存で変わった項目の説明（初回は初期値からの変化）" do
    setting = build(scheduled_work_time: "7:00", closing_day: "20")
    setting.save!
    assert_equal [ "1日の所定労働時間 8:00 → 7:00", "締め日 月末 → 20日" ], setting.saved_change_descriptions

    setting = WorkRuleSetting.current
    setting.update!(standard_break_time: "0:45", closing_day: "", overtime_warning_hours: "40")
    assert_equal [ "標準の休憩時間 1:00 → 0:45", "締め日 20日 → 月末", "残業時間の警告ライン 45時間 → 40時間" ],
                 setting.saved_change_descriptions

    setting = WorkRuleSetting.current
    setting.update!(scheduled_work_time: "07:00")
    assert_empty setting.saved_change_descriptions
  end
end
