# 月度の期間の決め方（F6 の締め日と、F14 の締め済みの月度から決める）。
#
# どの日も、ちょうど1つの月度に入る（重なりも抜けも出ない）ように決める。
# - 締め済みの月度：締めた時点の期間のまま（締めた後に締め日を変えても変わらない）
# - 未締めの月度
#   - 直前の月度が締め済みなら、開始日は「締め済みの月度の終了日の翌日」
#   - 直後の月度が締め済みなら、終了日は「締め済みの月度の開始日の前日」
#   - それ以外の端は、今の締め日どおり
#   例：20日締めで「11月度（10/21〜11/20）」を締めた後に月末締めへ変えると、「12月」は 11/21〜12/31、
#       「10月」は 10/1〜10/20 になる（15日締めへ変えた場合は「12月度」が 11/21〜12/15）。
#
# 期間はどれも「前の月の16日以降に始まり、その月の末日までに終わる」ので（締め日は 15・20・25日か月末）、
# ある日を含む月度は、その日の月か翌月の月度のどちらかになる（#containing はとなりの月度まで調べる）。
class AttendanceCalendar
  attr_reader :closing_day, :closings

  # closings … 締め済み（解除されていない）の月度の記録（MonthlyClosing）
  def initialize(closing_day: nil, closings: [])
    @closing_day = closing_day
    @closings = closings.to_a
    @closings_by_month = @closings.index_by { |closing| [ closing.year, closing.month ] }
  end

  # year 年 month 月の月度
  def period(year, month)
    if (closing = closing_for(year, month))
      return AttendancePeriod.new(year: year, month: month, closing_day: closing.closing_day,
                                  start_date: closing.start_date, end_date: closing.end_date, closing: closing, calendar: self)
    end

    first = Date.new(year, month, 1)
    previous_closing = closing_for(first.prev_month.year, first.prev_month.month)
    next_closing = closing_for(first.next_month.year, first.next_month.month)
    AttendancePeriod.new(year: year, month: month, closing_day: closing_day,
                         start_date: previous_closing && (previous_closing.end_date + 1),
                         end_date: next_closing && (next_closing.start_date - 1), calendar: self)
  end

  # date を含む月度
  def containing(date)
    base = AttendancePeriod.containing(date, closing_day: closing_day)
    candidates = [ 0, -1, 1 ].map do |offset|
      first = base.first_of_month >> offset
      period(first.year, first.month)
    end
    candidates.find { |candidate| candidate.include?(date) } || candidates.first
  end

  # 「2026-11」のような文字列から月度を作る。解釈できなければ nil
  def parse(value)
    year, month = AttendancePeriod.parse_year_month(value)
    period(year, month) if year
  end

  # date が締め済みの月度に入るか
  def closed_on?(date)
    closings.any? { |closing| closing.start_date <= date && date <= closing.end_date }
  end

  private

  def closing_for(year, month)
    @closings_by_month[[ year, month ]]
  end
end
