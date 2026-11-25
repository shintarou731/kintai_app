require "test_helper"

class PaidLeaveGrantTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @employee = users(:employee)
    @admin = users(:admin)
    travel_to Time.zone.local(2026, 11, 25, 10, 0)
  end

  teardown { travel_back }

  def build(**attributes)
    PaidLeaveGrant.new({ user: @employee, granted_by: @admin, granted_on: Date.new(2026, 10, 1), days: "10" }.merge(attributes))
  end

  test "有効期限を入れなければ、付与日の2年後になる" do
    grant = build(expires_on: nil)
    assert grant.save, grant.errors.full_messages.inspect
    assert_equal Date.new(2028, 10, 1), grant.expires_on
    assert_equal 20, grant.half_days
    assert_equal 10, grant.granted_days
  end

  test "2/29 に付与した場合の2年後は 2/28" do
    assert_equal Date.new(2026, 2, 28), PaidLeaveGrant.default_expiry_for(Date.new(2024, 2, 29))
  end

  test "日数は0.5日単位で保存する（7.5日 → 15）" do
    grant = build(days: "7.5")
    assert grant.save
    assert_equal 15, grant.reload.half_days
    assert_equal Rational(15, 2), grant.granted_days
    assert_equal BigDecimal("7.5"), grant.days
  end

  test "0.5日単位でない日数・0日以下・上限を超える日数・空欄は登録できない" do
    { "0.3" => /0.5日単位/, "0" => /0.5日以上/, "-1" => /0.5日以上/, "41" => /40日以下/, "" => /日数を入力/ }.each do |value, message|
      grant = build(days: value)
      assert_not grant.valid?, value
      assert_match message, grant.errors.full_messages.join, value
    end
  end

  test "数値として読めない日数は「数値で入力してください」になる。全角の数字は受け付ける（スプリント10の評価の指摘）" do
    %w[abc 1日 10a 1.2.3].each do |value|
      grant = build(days: value)
      assert_not grant.valid?, value
      assert_equal [ "日数は数値で入力してください（例：10、7.5）" ], grant.errors.full_messages, value
    end

    grant = build(days: "７．５")
    assert grant.valid?, grant.errors.full_messages.inspect
    assert_equal 15, grant.half_days
  end

  test "付与日は今日まで。未来の付与日は登録できない" do
    assert build(granted_on: Date.new(2026, 11, 25)).valid?
    grant = build(granted_on: Date.new(2026, 11, 26))
    assert_not grant.valid?
    assert_includes grant.errors.full_messages, "付与日に未来の日付は指定できません（今日までの日付にしてください）"
  end

  test "有効期限は付与日より前にできない（付与日と同じ日は可）" do
    assert build(expires_on: Date.new(2026, 10, 1)).valid?
    grant = build(expires_on: Date.new(2026, 9, 30))
    assert_not grant.valid?
    assert_includes grant.errors.full_messages, "有効期限は付与日と同じか、付与日より後の日付にしてください"
  end

  test "付与日と有効期限は必須" do
    grant = build(granted_on: nil, expires_on: nil)
    assert_not grant.valid?
    assert_includes grant.errors.full_messages, "付与日を入力してください"
  end

  test "usable_on? は付与日〜有効期限の日を含む" do
    grant = build(granted_on: Date.new(2026, 4, 1), expires_on: Date.new(2028, 4, 1))
    assert_not grant.usable_on?(Date.new(2026, 3, 31))
    assert grant.usable_on?(Date.new(2026, 4, 1))
    assert grant.usable_on?(Date.new(2028, 4, 1))
    assert_not grant.usable_on?(Date.new(2028, 4, 2))
  end
end
