require "test_helper"

class AttendancePeriodTest < ActiveSupport::TestCase
  test "月末締めの月度は1日〜末日" do
    period = AttendancePeriod.new(year: 2026, month: 11)
    assert_equal Date.new(2026, 11, 1), period.start_date
    assert_equal Date.new(2026, 11, 30), period.end_date
    assert_equal 30, period.dates.size
    assert_equal "2026年11月", period.label
    assert_equal "2026-11", period.to_param
  end

  test "うるう年の2月は29日まで" do
    assert_equal Date.new(2028, 2, 29), AttendancePeriod.new(year: 2028, month: 2).end_date
    assert_equal Date.new(2026, 2, 28), AttendancePeriod.new(year: 2026, month: 2).end_date
  end

  test "前月・翌月は年をまたいで移動できる" do
    january = AttendancePeriod.new(year: 2027, month: 1)
    assert_equal [ 2026, 12 ], [ january.previous.year, january.previous.month ]
    december = AttendancePeriod.new(year: 2026, month: 12)
    assert_equal [ 2027, 1 ], [ december.next.year, december.next.month ]
  end

  test "日付を含む月度（月末締め）" do
    period = AttendancePeriod.containing(Date.new(2026, 11, 30))
    assert_equal "2026-11", period.to_param
    assert period.include?(Date.new(2026, 11, 1))
    assert_not period.include?(Date.new(2026, 12, 1))
  end

  test "締め日がある場合の月度（20日締めの11月度は 10/21〜11/20）" do
    period = AttendancePeriod.new(year: 2026, month: 11, closing_day: 20)
    assert_equal Date.new(2026, 10, 21), period.start_date
    assert_equal Date.new(2026, 11, 20), period.end_date
    assert_equal "2026年11月度", period.label

    assert_equal "2026-11", AttendancePeriod.containing(Date.new(2026, 11, 20), closing_day: 20).to_param
    assert_equal "2026-12", AttendancePeriod.containing(Date.new(2026, 11, 21), closing_day: 20).to_param
    assert_equal Date.new(2026, 12, 26), AttendancePeriod.new(year: 2027, month: 1, closing_day: 25).start_date
  end

  test "「YYYY-MM」形式の文字列から作る。不正な値は nil" do
    assert_equal AttendancePeriod.new(year: 2026, month: 3), AttendancePeriod.parse("2026-03")
    [ nil, "", "2026-13", "2026-00", "2026-3", "abc", "1999-12", "2101-01", "2026-11-01" ].each do |value|
      assert_nil AttendancePeriod.parse(value), "#{value.inspect} は解釈できないはず"
    end
  end

  test "画面で移動できる年の範囲" do
    assert AttendancePeriod.new(year: 2000, month: 1).navigable?
    assert_not AttendancePeriod.new(year: 2000, month: 1).previous.navigable?
    assert_not AttendancePeriod.new(year: 2100, month: 12).next.navigable?
  end

  # --- 締め日の境界（F6） ---

  test "20日締め：10/20 は10月度、10/21〜11/20 は11月度、11/21 は12月度" do
    containing = ->(date) { AttendancePeriod.containing(date, closing_day: 20) }
    assert_equal "2026-10", containing.(Date.new(2026, 10, 20)).to_param
    assert_equal "2026-11", containing.(Date.new(2026, 10, 21)).to_param
    assert_equal "2026-11", containing.(Date.new(2026, 11, 20)).to_param
    assert_equal "2026-12", containing.(Date.new(2026, 11, 21)).to_param

    november = AttendancePeriod.new(year: 2026, month: 11, closing_day: 20)
    assert_equal Date.new(2026, 10, 21), november.dates.first
    assert_equal Date.new(2026, 11, 20), november.dates.last
    assert_equal 31, november.dates.size
    assert_not november.include?(Date.new(2026, 10, 20))
    assert november.include?(Date.new(2026, 10, 21))
    assert november.include?(Date.new(2026, 11, 20))
    assert_not november.include?(Date.new(2026, 11, 21))
    assert_equal "月度", november.unit
  end

  test "20日締め：前の月度・次の月度は隙間なくつながる（年をまたぐ場合も）" do
    november = AttendancePeriod.new(year: 2026, month: 11, closing_day: 20)
    assert_equal november.start_date - 1, november.previous.end_date
    assert_equal november.end_date + 1, november.next.start_date

    january = AttendancePeriod.new(year: 2027, month: 1, closing_day: 20)
    assert_equal Date.new(2026, 12, 21), january.start_date
    assert_equal Date.new(2027, 1, 20), january.end_date
    assert_equal "2027-01", AttendancePeriod.containing(Date.new(2026, 12, 21), closing_day: 20).to_param
    assert_equal "2026-12", AttendancePeriod.containing(Date.new(2026, 12, 20), closing_day: 20).to_param
  end

  test "15日締め：2/15 は2月度、2/16 は3月度。2月度は 1/16〜2/15" do
    assert_equal "2027-02", AttendancePeriod.containing(Date.new(2027, 2, 15), closing_day: 15).to_param
    assert_equal "2027-03", AttendancePeriod.containing(Date.new(2027, 2, 16), closing_day: 15).to_param

    february = AttendancePeriod.new(year: 2027, month: 2, closing_day: 15)
    assert_equal Date.new(2027, 1, 16), february.start_date
    assert_equal Date.new(2027, 2, 15), february.end_date
    march = AttendancePeriod.new(year: 2027, month: 3, closing_day: 15)
    assert_equal Date.new(2027, 2, 16), march.start_date # 2月末（28日）をまたぐ
    assert_equal Date.new(2027, 3, 15), march.end_date
    assert_equal 28, march.dates.size
  end

  test "2月末：月末締めは 2/28（うるう年は 2/29）まで、3/1 から3月。25日締めの3月度は 2/26〜3/25" do
    assert_equal "2027-02", AttendancePeriod.containing(Date.new(2027, 2, 28)).to_param
    assert_equal "2027-03", AttendancePeriod.containing(Date.new(2027, 3, 1)).to_param
    assert_equal "2028-02", AttendancePeriod.containing(Date.new(2028, 2, 29)).to_param

    assert_equal "2027-03", AttendancePeriod.containing(Date.new(2027, 2, 28), closing_day: 25).to_param
    march = AttendancePeriod.new(year: 2027, month: 3, closing_day: 25)
    assert_equal Date.new(2027, 2, 26), march.start_date
    assert_equal Date.new(2027, 3, 25), march.end_date
    assert_equal "2028-03", AttendancePeriod.containing(Date.new(2028, 2, 29), closing_day: 20).to_param
  end
end
