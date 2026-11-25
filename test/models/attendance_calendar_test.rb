require "test_helper"

# 月度の期間の決め方（F14）：締め済みの月度は締めた時点の期間のまま。となりの未締めの月度は、重なり・すき間が出ないように端を合わせる
class AttendanceCalendarTest < ActiveSupport::TestCase
  def closing(year, month, from, to, closing_day: nil)
    MonthlyClosing.new(year: year, month: month, start_date: from, end_date: to, closing_day: closing_day,
                       scheduled_work_minutes: 480, standard_break_minutes: 60, overtime_warning_hours: 45, closed_at: Time.current)
  end

  def range(period)
    [ period.start_date, period.end_date ]
  end

  # 20日締めで締めた「11月度（10/21〜11/20）」
  def november_20
    closing(2026, 11, Date.new(2026, 10, 21), Date.new(2026, 11, 20), closing_day: 20)
  end

  # from〜to のどの日も、ちょうど1つの月度に入る（重なり・抜けが無い）ことを確かめる
  def assert_each_day_in_exactly_one_period(calendar, from, to)
    months = (from.prev_month.beginning_of_month..to.next_month).map(&:beginning_of_month).uniq
    periods = months.map { |date| calendar.period(date.year, date.month) }
    (from..to).each do |date|
      owners = periods.select { |period| period.include?(date) }
      assert_equal 1, owners.size, "#{date} は #{owners.map(&:label)} に入っています"
      assert_equal owners.first.to_param, calendar.containing(date).to_param, "#{date} を含む月度"
    end
    periods.each_cons(2) { |earlier, later| assert_equal earlier.end_date + 1, later.start_date, "#{earlier.label} と #{later.label} の間" }
  end

  test "締めが無ければ、締め日どおりの期間" do
    calendar = AttendanceCalendar.new(closing_day: 20)
    november = calendar.period(2026, 11)
    assert_equal [ Date.new(2026, 10, 21), Date.new(2026, 11, 20) ], range(november)
    assert_not november.closed?
    assert_not november.adjusted?
  end

  test "締め済みの月度は、締め日を変えても締めた時点の期間のまま" do
    [ nil, 15, 20, 25 ].each do |closing_day|
      period = AttendanceCalendar.new(closing_day: closing_day, closings: [ november_20 ]).period(2026, 11)
      assert period.closed?
      assert_equal [ Date.new(2026, 10, 21), Date.new(2026, 11, 20) ], range(period)
      assert_equal "2026年11月度", period.label
    end
  end

  test "仕様の例：20日締めで11月度を締めた後に月末締めへ変えると、12月は 11/21〜12/31、10月は 10/1〜10/20" do
    calendar = AttendanceCalendar.new(closing_day: nil, closings: [ november_20 ])
    december = calendar.period(2026, 12)
    assert_equal [ Date.new(2026, 11, 21), Date.new(2026, 12, 31) ], range(december)
    assert december.adjusted?
    assert_equal [ Date.new(2026, 10, 1), Date.new(2026, 10, 20) ], range(calendar.period(2026, 10))
    assert_equal [ Date.new(2027, 1, 1), Date.new(2027, 1, 31) ], range(calendar.period(2027, 1))
    assert_equal [ Date.new(2026, 9, 1), Date.new(2026, 9, 30) ], range(calendar.period(2026, 9))
    assert_each_day_in_exactly_one_period(calendar, Date.new(2026, 8, 1), Date.new(2027, 3, 31))
  end

  test "仕様の例：15日締めへ変えた場合は、12月度は 11/21〜12/15" do
    calendar = AttendanceCalendar.new(closing_day: 15, closings: [ november_20 ])
    assert_equal [ Date.new(2026, 11, 21), Date.new(2026, 12, 15) ], range(calendar.period(2026, 12))
    assert_equal [ Date.new(2026, 9, 16), Date.new(2026, 10, 20) ], range(calendar.period(2026, 10))
    assert_equal [ Date.new(2026, 12, 16), Date.new(2027, 1, 15) ], range(calendar.period(2027, 1))
    assert_each_day_in_exactly_one_period(calendar, Date.new(2026, 8, 1), Date.new(2027, 3, 31))
  end

  test "25日締めへ変えた場合も、重なり・すき間が出ない" do
    calendar = AttendanceCalendar.new(closing_day: 25, closings: [ november_20 ])
    assert_equal [ Date.new(2026, 11, 21), Date.new(2026, 12, 25) ], range(calendar.period(2026, 12))
    assert_equal [ Date.new(2026, 9, 26), Date.new(2026, 10, 20) ], range(calendar.period(2026, 10))
    assert_each_day_in_exactly_one_period(calendar, Date.new(2026, 8, 1), Date.new(2027, 3, 31))
  end

  test "締め済みの月度が続けて並んでも（締め日の違う月度が混ざっても）、どの日もちょうど1つの月度に入る" do
    december = closing(2026, 12, Date.new(2026, 11, 21), Date.new(2026, 12, 31))
    [ nil, 15, 20, 25 ].each do |closing_day|
      calendar = AttendanceCalendar.new(closing_day: closing_day, closings: [ november_20, december ])
      assert_equal [ Date.new(2026, 11, 21), Date.new(2026, 12, 31) ], range(calendar.period(2026, 12))
      assert_equal Date.new(2027, 1, 1), calendar.period(2027, 1).start_date
      assert_each_day_in_exactly_one_period(calendar, Date.new(2026, 7, 1), Date.new(2027, 4, 30))
    end
  end

  test "直後の月度だけが締め済みなら、未締めの月度の終了日は締め済みの月度の開始日の前日" do
    # 月末締めで 12月（12/1〜12/31）を締め、11月は未締めのまま 20日締めに変えた
    december = closing(2026, 12, Date.new(2026, 12, 1), Date.new(2026, 12, 31))
    calendar = AttendanceCalendar.new(closing_day: 20, closings: [ december ])
    assert_equal [ Date.new(2026, 10, 21), Date.new(2026, 11, 30) ], range(calendar.period(2026, 11))
    assert_equal [ Date.new(2027, 1, 1), Date.new(2027, 1, 20) ], range(calendar.period(2027, 1))
    assert_each_day_in_exactly_one_period(calendar, Date.new(2026, 8, 1), Date.new(2027, 3, 31))
  end

  test "前後の月度への移動も、同じ決め方の期間になる" do
    calendar = AttendanceCalendar.new(closing_day: nil, closings: [ november_20 ])
    december = calendar.period(2026, 12)
    assert december.previous.closed?
    assert_equal [ Date.new(2026, 10, 1), Date.new(2026, 10, 20) ], range(december.previous.previous)
    assert_equal december.to_param, december.previous.next.to_param
    assert_equal [ Date.new(2026, 11, 21), Date.new(2026, 12, 31) ], range(calendar.parse("2026-12"))
    assert_nil calendar.parse("2026-13")
  end

  test "WorkRules は締め済みの月度を読み込み、同じ決め方で期間を返す" do
    rules = WorkRules.new(closing_day: nil, closings: [ november_20 ])
    assert_equal "2026-12", rules.period_containing(Date.new(2026, 11, 21)).to_param
    assert_equal "2026-11", rules.period_containing(Date.new(2026, 11, 20)).to_param
    assert_equal "2026-10", rules.period_containing(Date.new(2026, 10, 20)).to_param
  end
end
