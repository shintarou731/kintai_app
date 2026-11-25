require "test_helper"

class HolidayCalendarTest < ActiveSupport::TestCase
  test "2026年11月23日（月）は勤労感謝の日で、休日" do
    date = Date.new(2026, 11, 23)
    assert_equal "勤労感謝の日", HolidayCalendar.holiday_name(date)
    assert HolidayCalendar.holiday?(date)
    assert HolidayCalendar.day_off?(date)
    assert_not HolidayCalendar.working_day?(date)
    assert_equal :holiday, HolidayCalendar.day_kind(date)
  end

  test "振替休日：2026年5月6日（水）は、日曜の憲法記念日（5/3）の振替休日" do
    assert_equal "憲法記念日", HolidayCalendar.holiday_name(Date.new(2026, 5, 3))
    assert_equal "振替休日", HolidayCalendar.holiday_name(Date.new(2026, 5, 6))
    assert_equal :holiday, HolidayCalendar.day_kind(Date.new(2026, 5, 6))
    # 2027年3月22日（月）も、日曜の春分の日（3/21）の振替休日
    assert_equal "振替休日", HolidayCalendar.holiday_name(Date.new(2027, 3, 22))
  end

  test "国民の休日：2026年9月22日（火）は、敬老の日（9/21）と秋分の日（9/23）に挟まれた国民の休日" do
    assert_equal "敬老の日", HolidayCalendar.holiday_name(Date.new(2026, 9, 21))
    assert_equal "国民の休日", HolidayCalendar.holiday_name(Date.new(2026, 9, 22))
    assert_equal "秋分の日", HolidayCalendar.holiday_name(Date.new(2026, 9, 23))
    assert HolidayCalendar.day_off?(Date.new(2026, 9, 22))
  end

  test "土曜が祝日の日（2028年1月1日・元日）は、土曜ではなく祝日として扱う" do
    date = Date.new(2028, 1, 1)
    assert date.saturday?
    assert_equal "元日", HolidayCalendar.holiday_name(date)
    assert_equal :holiday, HolidayCalendar.day_kind(date)
    assert HolidayCalendar.day_off?(date)
  end

  test "日曜が祝日の日（2026年5月3日・憲法記念日）も祝日として扱う" do
    assert_equal :holiday, HolidayCalendar.day_kind(Date.new(2026, 5, 3))
  end

  test "祝日ではない土曜・日曜・平日" do
    assert_equal :saturday, HolidayCalendar.day_kind(Date.new(2026, 11, 21))
    assert_equal :sunday, HolidayCalendar.day_kind(Date.new(2026, 11, 22))
    assert_equal :weekday, HolidayCalendar.day_kind(Date.new(2026, 11, 24))
    assert_nil HolidayCalendar.holiday_name(Date.new(2026, 11, 21))
    assert HolidayCalendar.day_off?(Date.new(2026, 11, 21))
    assert HolidayCalendar.day_off?(Date.new(2026, 11, 22))
    assert HolidayCalendar.working_day?(Date.new(2026, 11, 24))
  end

  test "年をまたぐ期間：2026年12月31日〜2027年1月4日の祝日は元日だけで、休日は 1/1〜1/3" do
    from = Date.new(2026, 12, 31)
    to = Date.new(2027, 1, 4)
    assert_equal({ Date.new(2027, 1, 1) => "元日" }, HolidayCalendar.holidays_between(from, to))
    assert_equal [ Date.new(2027, 1, 1), Date.new(2027, 1, 2), Date.new(2027, 1, 3) ],
                 (from..to).select { |date| HolidayCalendar.day_off?(date) }
    assert HolidayCalendar.working_day?(Date.new(2026, 12, 31))
  end

  test "日時（Time）を渡しても日付で判定する" do
    assert_equal "勤労感謝の日", HolidayCalendar.holiday_name(Time.zone.local(2026, 11, 23, 23, 59))
  end
  # HolidayCalendar は gem の祝日データ（HolidayJp.holidays.holidays の Hash）を直接引いている（全件を走査しないため）。
  # gem を更新して内部の構造が変わったときに気付けるよう、gem 自身の公開の判定（HolidayJp.holiday?）と結果が一致することを
  # 2025〜2028年の毎日で確かめる（スプリント 9.2 の評価の所見への対応）。
  test "gem 自身の判定（HolidayJp.holiday?）と、2025〜2028年の毎日で結果が一致する" do
    mismatches = (Date.new(2025, 1, 1)..Date.new(2028, 12, 31)).reject do |date|
      HolidayJp.holiday?(date) == HolidayCalendar.holiday?(date)
    end
    assert_equal [], mismatches
    # 名前も gem の公開の API（HolidayJp.between）と一致する
    from = Date.new(2026, 1, 1)
    to = Date.new(2027, 12, 31)
    expected = HolidayJp.between(from, to).to_h { |holiday| [ holiday.date, holiday.name ] }
    assert_equal expected, HolidayCalendar.holidays_between(from, to)
  end
end
