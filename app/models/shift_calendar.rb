# 従業員の「シフト」画面（F12）の、1か月分のカレンダー。月曜はじまりの週で、その月の1日〜末日を並べる。
#
# - 予定は、公開済みのシフト（published_*）だけを使う。下書き・公開後に変えてまだ公開していない内容は出さない。
#   公開済みのシフトを削除して、まだ公開していないものは、次の公開まで公開中の内容のまま出す（Shift.published）。
# - カレンダーは暦の月（1日〜末日）。締め日（F6）に従う月度は、勤怠履歴（F5）と管理者の予実の確認で使う。
# - 各日には、承認済みの休暇・承認待ちの休暇と、過去の日の予実比較（ShiftCheck：遅刻・早退・欠勤）も持つ。
class ShiftCalendar
  Day = Struct.new(:date, :in_month, :shift, :leaves, :check, keyword_init: true) do
    def in_month?
      in_month
    end

    def day_kind
      HolidayCalendar.day_kind(date)
    end

    def holiday_name
      HolidayCalendar.holiday_name(date)
    end

    def effective_leaves
      leaves.select(&:effective?)
    end

    def pending_leaves
      leaves.reject(&:effective?)
    end

    def full_day_leave
      effective_leaves.find(&:full_day?)
    end

    # 公開後に内容が変わったシフト（再公開で変わったもの）
    def revised?
      !shift&.revised_at.nil?
    end
  end

  attr_reader :user, :month, :now

  # month … その月の1日（Date）
  def initialize(user, month:, now: Time.current)
    @user = user
    @month = month.beginning_of_month
    @now = now.in_time_zone
  end

  def today
    now.to_date
  end

  def date_range
    month..month.end_of_month
  end

  def current_month?
    date_range.cover?(today)
  end

  def previous_month
    month.prev_month
  end

  def next_month
    month.next_month
  end

  # 画面で移動できる月か（URL の書き換えで極端な年を指定されたときのため）
  def self.navigable?(month)
    AttendancePeriod::YEAR_RANGE.cover?(month.year)
  end

  # 「2026-11」→ その月の1日。解釈できなければ nil
  def self.parse_month(value)
    period = AttendancePeriod.parse(value)
    period&.first_of_month
  end

  def label
    "#{month.year}年#{month.month}月"
  end

  # 月曜はじまりの週（前後の月の日も含めて7日ずつ）
  def weeks
    @weeks ||= begin
      from = month.beginning_of_week(:monday)
      to = month.end_of_month.end_of_week(:monday)
      (from..to).map { |date| day(date) }.each_slice(7).to_a
    end
  end

  # その月の日（前後の月の日を除く）
  def days
    weeks.flatten.select(&:in_month?)
  end

  def scheduled_days
    days.select(&:shift)
  end

  # この月の予定の実働の合計（分。公開中のシフトの時間から休憩を引いた時間）
  def scheduled_work_minutes
    scheduled_days.sum { |item| item.shift.published_scheduled_work_minutes }
  end

  def revised_days
    scheduled_days.select(&:revised?)
  end

  private

  def day(date)
    in_month = date_range.cover?(date)
    shift = shifts_by_date[date]
    leaves = leaves_on(date)
    check = ShiftCheck.new(shift: shift, attendance: attendances_by_date[date], leaves: leaves.select(&:effective?), now: now)
    Day.new(date: date, in_month: in_month, shift: shift, leaves: leaves, check: check)
  end

  def calendar_range
    month.beginning_of_week(:monday)..month.end_of_month.end_of_week(:monday)
  end

  def shifts_by_date
    @shifts_by_date ||= user.shifts.published.where(work_date: calendar_range).index_by(&:work_date)
  end

  def attendances_by_date
    @attendances_by_date ||= user.attendances.where(work_date: calendar_range).index_by(&:work_date)
  end

  # 承認済み（取り消されていない）と承認待ちの休暇
  def all_leaves
    @all_leaves ||= user.leave_requests.blocking.overlapping(calendar_range.begin, calendar_range.end).order(:target_date, :id).to_a
  end

  def leaves_on(date)
    all_leaves.select { |leave| leave.covers?(date) }
  end
end
