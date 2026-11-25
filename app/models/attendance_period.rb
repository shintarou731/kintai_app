# 勤怠を集計する「1か月」（月度）。
#
# - 月末締め（closing_day が nil）：「11月」は 11/1〜11/30
# - 締め日あり（例：20日締め）：「11月度」は 10/21〜11/20
#
# 締め（F14）があると、締め日だけでは期間が決まらないことがある（締め日を変えた後など）。
# そのときは AttendanceCalendar が期間（start_date・end_date）を決めて渡す。
# - 締め済みの月度：締めた時点の期間（closing に締めの記録が入る）
# - 締め済みの月度のとなりの未締めの月度：重なり・すき間が出ないように、端を締め済みの月度に合わせる
# 期間を渡さなければ、締め日どおりの期間（nominal_start_date〜nominal_end_date）になる。
class AttendancePeriod
  include Comparable

  # 画面で行き来できる年の範囲（URL の書き換えで極端な年を指定されたときのため）
  YEAR_RANGE = (2000..2100)
  PARAM_FORMAT = /\A(\d{4})-(\d{2})\z/

  attr_reader :year, :month, :closing_day, :closing, :calendar

  def self.containing(date, closing_day: nil)
    base = closing_day && date.day > closing_day ? date.next_month : date
    new(year: base.year, month: base.month, closing_day: closing_day)
  end

  # 「2026-11」形式の文字列から作る。解釈できない・範囲外なら nil
  def self.parse(value, closing_day: nil)
    year, month = parse_year_month(value)
    return unless year

    new(year: year, month: month, closing_day: closing_day)
  end

  # 「2026-11」→ [2026, 11]。解釈できない・範囲外なら nil
  def self.parse_year_month(value)
    match = PARAM_FORMAT.match(value.to_s)
    return unless match

    year = match[1].to_i
    month = match[2].to_i
    [ year, month ] if YEAR_RANGE.cover?(year) && (1..12).cover?(month)
  end

  # start_date / end_date … 締め日どおりでない期間（AttendanceCalendar が決める）。nil なら締め日どおり
  # closing  … 締め済みの月度なら、その締めの記録（MonthlyClosing）
  # calendar … 前後の月度を同じ決め方で作るための AttendanceCalendar（nil なら締め日どおり）
  def initialize(year:, month:, closing_day: nil, start_date: nil, end_date: nil, closing: nil, calendar: nil)
    @year = year
    @month = month
    @closing_day = closing_day
    @start_date = start_date
    @end_date = end_date
    @closing = closing
    @calendar = calendar
  end

  def first_of_month
    Date.new(year, month, 1)
  end

  # 締め日どおりの期間
  def nominal_start_date
    closing_day ? first_of_month.prev_month.change(day: closing_day) + 1 : first_of_month
  end

  def nominal_end_date
    closing_day ? first_of_month.change(day: closing_day) : first_of_month.end_of_month
  end

  def start_date
    @start_date || nominal_start_date
  end

  def end_date
    @end_date || nominal_end_date
  end

  # 締め済みの月度か
  def closed?
    !closing.nil?
  end

  # 未締めの月度で、となりの締め済みの月度に合わせて、締め日どおりの期間から端を動かしたか
  def adjusted?
    !closed? && [ start_date, end_date ] != [ nominal_start_date, nominal_end_date ]
  end

  def date_range
    start_date..end_date
  end

  def dates
    date_range.to_a
  end

  def include?(date)
    date_range.cover?(date)
  end

  # 期間が終わったか（締められるのは終わった月度だけ）
  def ended?(today: Date.current)
    end_date < today
  end

  def previous
    shift(-1)
  end

  def next
    shift(1)
  end

  # 画面で移動できる範囲か（前月・翌月リンクを出すかの判断に使う）
  def navigable?
    YEAR_RANGE.cover?(year)
  end

  # URL のパラメーター（「2026-11」）
  def to_param
    format("%04d-%02d", year, month)
  end

  # 見出し（「2026年11月」、締め日ありなら「2026年11月度」）
  def label
    closing_day ? "#{year}年#{month}月度" : "#{year}年#{month}月"
  end

  # 「月」の呼び方（月末締めは「月」、締め日ありは「月度」）。「今月」「今月度」などに使う
  def unit
    closing_day ? "月度" : "月"
  end

  def <=>(other)
    return unless other.is_a?(AttendancePeriod)

    [ year, month ] <=> [ other.year, other.month ]
  end

  private

  def shift(months)
    date = first_of_month >> months
    return calendar.period(date.year, date.month) if calendar

    self.class.new(year: date.year, month: date.month, closing_day: closing_day)
  end
end
