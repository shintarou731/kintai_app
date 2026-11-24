# 勤怠を集計する「1か月」（月度）。
#
# - 月末締め（closing_day が nil）：「11月」は 11/1〜11/30
# - 締め日あり（例：20日締め）：「11月度」は 10/21〜11/20
class AttendancePeriod
  include Comparable

  # 画面で行き来できる年の範囲（URL の書き換えで極端な年を指定されたときのため）
  YEAR_RANGE = (2000..2100)
  PARAM_FORMAT = /\A(\d{4})-(\d{2})\z/

  attr_reader :year, :month, :closing_day

  def self.containing(date, closing_day: nil)
    base = closing_day && date.day > closing_day ? date.next_month : date
    new(year: base.year, month: base.month, closing_day: closing_day)
  end

  # 「2026-11」形式の文字列から作る。解釈できない・範囲外なら nil
  def self.parse(value, closing_day: nil)
    match = PARAM_FORMAT.match(value.to_s)
    return unless match

    year = match[1].to_i
    month = match[2].to_i
    return unless YEAR_RANGE.cover?(year) && (1..12).cover?(month)

    new(year: year, month: month, closing_day: closing_day)
  end

  def initialize(year:, month:, closing_day: nil)
    @year = year
    @month = month
    @closing_day = closing_day
  end

  def first_of_month
    Date.new(year, month, 1)
  end

  def start_date
    closing_day ? first_of_month.prev_month.change(day: closing_day) + 1 : first_of_month
  end

  def end_date
    closing_day ? first_of_month.change(day: closing_day) : first_of_month.end_of_month
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
    self.class.new(year: date.year, month: date.month, closing_day: closing_day)
  end
end
