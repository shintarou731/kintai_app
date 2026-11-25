# シフト表（F11）の1週間分の表示用データ。縦に有効な従業員、横に月〜日の7日。
#
# - 無効な従業員は表に出さない（その週にシフトが残っていれば #inactive_shifts で別に見せる）。日ごとの人数にも数えない。
# - マス（Cell）には、その日のシフト（削除予定を含む）と、承認済みで取り消されていない休暇を持つ。
# - 週の状態（#status）
#   - :empty     … シフトも公開の記録も無い
#   - :draft     … 一度も公開していない（未公開のシフトがある）
#   - :changed   … 公開した後に、まだ公開していない変更がある
#   - :published … 公開済みで、未公開の変更は無い
class ShiftBoard
  DAYS = 7
  HISTORY_LIMIT = 5

  Cell = Struct.new(:user, :date, :shift, :leaves, keyword_init: true) do
    # 下書きの上で存在するシフト（削除予定を除く）
    def live_shift
      shift if shift&.live?
    end

    def removing_shift
      shift if shift&.removed?
    end

    def full_day_leave
      leaves.find(&:full_day?)
    end

    def half_day_leaves
      leaves.select(&:half_day?)
    end

    # 全日の休暇の日にシフトがある
    def leave_conflict?
      !live_shift.nil? && !full_day_leave.nil?
    end

    # シフトの時間が半休の時間（HalfDayLeaveWindow）と重なる半休
    def half_day_conflict_leaves
      return [] if live_shift.nil?

      half_day_leaves.select { |leave| HalfDayLeaveWindow.overlaps?(leave, date, live_shift.starts_at, live_shift.ends_at) }
    end
  end

  attr_reader :week_start, :today

  def self.week_start_for(date)
    date.to_date.beginning_of_week(:monday)
  end

  # 開ける週の範囲（今日から前後1年の日を含む週）
  def self.navigable_range(today: Date.current)
    range = Shift.editable_range(today: today)
    week_start_for(range.begin)..week_start_for(range.end)
  end

  # ?week=2026-11-25 → その日を含む週の月曜日。解釈できない・範囲外なら nil
  def self.parse_week(value, today: Date.current)
    date = Date.strptime(value.to_s, "%Y-%m-%d")
    monday = week_start_for(date)
    monday if navigable_range(today: today).cover?(monday)
  rescue Date::Error
    nil
  end

  def initialize(week_start:, today: Date.current)
    @week_start = self.class.week_start_for(week_start)
    @today = today
  end

  def week_end
    week_start + (DAYS - 1)
  end

  def week_range
    week_start..week_end
  end

  def dates
    week_range.to_a
  end

  def current_week?
    week_range.cover?(today)
  end

  def previous_week
    week = week_start - DAYS
    week if self.class.navigable_range(today: today).cover?(week)
  end

  def next_week
    week = week_start + DAYS
    week if self.class.navigable_range(today: today).cover?(week)
  end

  def users
    @users ||= User.active.order(:id).to_a
  end

  def cell(user, date)
    Cell.new(user: user, date: date, shift: shift_index[[ user.id, date ]], leaves: leaves_on(user.id, date))
  end

  # その日のシフト人数（有効な従業員の、削除予定を除くシフト）
  def count_on(date)
    active_live_shifts.count { |shift| shift.work_date == date }
  end

  # その週の実働の予定（分）
  def weekly_minutes(user)
    active_live_shifts.select { |shift| shift.user_id == user.id }.sum(&:scheduled_work_minutes)
  end

  def total_count
    active_live_shifts.size
  end

  # 無効な従業員のシフト（表には出さない。日付の順）
  def inactive_shifts
    shifts.reject { |shift| shift.user.active? }.sort_by { |shift| [ shift.work_date, shift.user_id ] }
  end

  # 次の公開で従業員に反映される変更（無効な従業員のシフトも含む）
  def pending_shifts
    @pending_shifts ||= shifts.select(&:pending_publication?)
  end

  def pending_counts
    counts = { added: 0, changed: 0, removed: 0 }
    pending_shifts.each do |shift|
      key = { draft: :added, changed: :changed, removing: :removed }.fetch(shift.state)
      counts[key] += 1
    end
    counts
  end

  def publications
    @publications ||= ShiftPublication.for_week(week_start).latest_first.includes(:published_by).limit(HISTORY_LIMIT).to_a
  end

  def last_publication
    publications.first
  end

  def status
    if pending_shifts.any?
      (last_publication || shifts.any?(&:published_once?)) ? :changed : :draft
    elsif last_publication || shifts.any?
      :published
    else
      :empty
    end
  end

  def copy_plan
    @copy_plan ||= ShiftWeekCopy.new(week_start: week_start, admin: nil).plan
  end

  def patterns
    @patterns ||= ShiftPattern.ordered.to_a
  end

  # 時刻と休憩がパターンと同じなら、そのパターン
  def pattern_for(shift)
    return if shift.nil?

    @pattern_index ||= ShiftPattern.index_by_times(patterns)
    @pattern_index[shift.times_key]
  end

  def holiday_name(date)
    HolidayCalendar.holiday_name(date)
  end

  def day_kind(date)
    HolidayCalendar.day_kind(date)
  end

  private

  def shifts
    @shifts ||= Shift.on_dates(week_range).includes(:user, :updated_by).order(:work_date, :user_id).to_a
  end

  def shift_index
    @shift_index ||= shifts.index_by { |shift| [ shift.user_id, shift.work_date ] }
  end

  def active_live_shifts
    @active_live_shifts ||= shifts.select { |shift| shift.live? && shift.user.active? }
  end

  def leaves_on(user_id, date)
    @leaves_by_user ||= LeaveRequest.effective.where(user_id: users.map(&:id)).overlapping(week_start, week_end)
                                    .order(:target_date, :id).to_a.group_by(&:user_id)
    (@leaves_by_user[user_id] || []).select { |leave| leave.covers?(date) }
  end
end
