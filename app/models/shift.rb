# シフト（勤務予定。F11）。管理者がシフト表のマス（従業員 × 日付）ごとに、開始時刻・終了時刻・休憩時間を登録する。
#
# - work_date はシフトが始まる日。日付をまたぐシフト（22:00〜翌6:00）も、開始した日のシフトとして扱う（勤務日と同じ考え方）。
#   1人1日1件（user_id × work_date で一意）。
# - 「下書き」と「公開」
#   - 管理者が編集するのは start_minute / end_minute / break_minutes（下書き）。
#   - 従業員に見せるのは、週の「公開」（ShiftWeekPublication）で写した published_* だけ。公開するまで、新しいシフトも変更も
#     従業員には見えない。従業員の画面（F12）は Shift.published と published_* を使うこと。
#   - 公開済みのシフトを削除すると removed_at が入り（削除予定）、次の公開で行ごと消える。それまで従業員には公開中の内容が見える。
#     一度も公開していないシフトは、削除するとすぐに消える。
#   - 状態（#state）：:draft（未公開）／:published（公開中の内容と同じ）／:changed（公開後に変更・未公開）／:removing（削除予定・未公開）
# - 同時編集：lock_version（楽観的ロック）。画面で読んだ時点の lock_version を送り、その後に他の管理者が保存していれば
#   ActiveRecord::StaleObjectError になる（呼び出し側で「他の管理者が先に変更しました」と知らせる）。
# - 承認済みの休暇（全日）の日にシフトを入れるには、確認（leave_acknowledged）が要る。半休の日は確認なしで入れられる（画面で注意を出す）。
class Shift < ApplicationRecord
  include ShiftTimeFields

  # シフトを登録できる日付・シフト表で開ける週の範囲（今日から前後1年）
  EDITABLE_SPAN = 1.year

  STATES = %i[draft published changed removing].freeze

  belongs_to :user
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  # 全日の休暇の日に登録することを、管理者が確認したか（フォームのチェックボックス）
  attribute :leave_acknowledged, :boolean, default: false

  # 管理者の下書きの上で存在するシフト（削除予定を除く）
  scope :live, -> { where(removed_at: nil) }
  # 一度でも公開されたシフト（従業員に見せるのは published_* の内容。削除予定のものも、次の公開までは見せる）
  scope :published, -> { where.not(published_start_minute: nil) }
  scope :on_dates, ->(range) { where(work_date: range) }

  validates :work_date, presence: true
  validate :work_date_must_be_editable, if: :changing_draft?
  validate :user_must_be_active, if: :changing_draft?
  validate :must_not_overlap_neighbor_shifts, if: :changing_draft?
  validate :full_day_leave_must_be_acknowledged, if: :changing_draft?

  def self.editable_range(today: Date.current)
    (today - EDITABLE_SPAN)..(today + EDITABLE_SPAN)
  end

  # date の minute 分（0:00 から）の時刻（JST）
  def self.time_on(date, minute)
    date.in_time_zone.beginning_of_day + minute.minutes
  end

  # 「9:00〜18:00」「22:00〜翌6:00」
  def self.range_label(start_minute, end_minute)
    return if start_minute.nil? || end_minute.nil?

    next_day = end_minute < start_minute ? "翌" : ""
    "#{format_clock_time(start_minute)}〜#{next_day}#{format_clock_time(end_minute)}"
  end

  # 休暇の表示に使う、承認済みで取り消されていない休暇（期間がこの日にかかるもの）
  def self.effective_leaves_on(user_id, date)
    LeaveRequest.effective.where(user_id: user_id).overlapping(date, date).order(:target_date, :id).to_a
  end

  def live?
    removed_at.nil?
  end

  def removed?
    !live?
  end

  # 一度でも公開されたか
  def published_once?
    !published_start_minute.nil?
  end

  def published_matches_draft?
    [ published_start_minute, published_end_minute, published_break_minutes ] == [ start_minute, end_minute, break_minutes ]
  end

  def state
    if removed? then :removing
    elsif !published_once? then :draft
    elsif published_matches_draft? then :published
    else :changed
    end
  end

  # DB に保存されている内容での状態。入力画面を、保存できなかった入力のまま再表示したとき（422）にも、
  # 入力した値ではなく、保存されている状態を出すために使う
  def stored_state
    return :draft if new_record?

    published = [ published_start_minute_in_database, published_end_minute_in_database, published_break_minutes_in_database ]
    if removed_at_in_database then :removing
    elsif published.first.nil? then :draft
    elsif published == [ start_minute_in_database, end_minute_in_database, break_minutes_in_database ] then :published
    else :changed
    end
  end

  # DB に保存されている下書きの時間帯（「9:00〜18:00」）
  def stored_range_label
    self.class.range_label(start_minute_in_database, end_minute_in_database)
  end

  # 次の「公開」で従業員に反映される変更があるか
  def pending_publication?
    state != :published
  end

  def range_label
    self.class.range_label(start_minute, end_minute)
  end

  def published_range_label
    self.class.range_label(published_start_minute, published_end_minute)
  end

  # 下書きの開始・終了の時刻（JST）
  def starts_at
    self.class.time_on(work_date, start_minute)
  end

  def ends_at
    self.class.time_on(overnight? ? work_date + 1 : work_date, end_minute)
  end

  # 公開中の開始・終了の時刻（従業員の画面・予実比較（F12）で使う）。一度も公開していなければ nil
  def published_starts_at
    published_once? ? self.class.time_on(work_date, published_start_minute) : nil
  end

  def published_ends_at
    return unless published_once?

    self.class.time_on(published_end_minute < published_start_minute ? work_date + 1 : work_date, published_end_minute)
  end

  def published_scheduled_work_minutes
    published_once? ? self.class.span_minutes(published_start_minute, published_end_minute) - published_break_minutes.to_i : nil
  end

  def effective_leaves
    @effective_leaves ||= self.class.effective_leaves_on(user_id, work_date)
  end

  def full_day_leave
    effective_leaves.find(&:full_day?)
  end

  def half_day_leaves
    effective_leaves.select(&:half_day?)
  end

  # 下書きの時間帯が、半休の時間（HalfDayLeaveWindow。午前半休＝〜12:00、午後半休＝13:00〜）と重なる半休。
  # 重なっても登録はできる（画面で注意を出す）
  def overlapping_half_day_leaves
    return [] if work_date.nil? || start_minute.nil? || end_minute.nil? || start_minute == end_minute

    half_day_leaves.select { |leave| HalfDayLeaveWindow.overlaps?(leave, work_date, starts_at, ends_at) }
  end

  # 半休と重なるときの注意（登録・変更・割り当てのメッセージに添える）。重ならなければ nil
  def half_day_overlap_note
    leaves = overlapping_half_day_leaves
    return if leaves.empty?

    windows = leaves.map { |leave| "#{leave.day_part_label}は#{HalfDayLeaveWindow.label(leave)}" }.join("・")
    "#{I18n.l(work_date, format: :short_with_day)} は #{user&.name} さんの#{leaves.map(&:day_label).join('・')}の日です。" \
      "シフト（#{range_label}）が半休の時間（#{windows}）と重なっています。時間を確かめてください。"
  end

  # 削除する。一度も公開していなければ行ごと消し、公開済みなら削除予定にする（次の公開で消える）。
  # lock_version が古ければ ActiveRecord::StaleObjectError
  def remove!(by:, now: Time.current)
    if published_once?
      self.removed_at = now
      self.updated_by = by
      save!(validate: false)
    else
      destroy!
    end
  end

  # 公開中の内容と下書きの内容を入れ替えずに、下書きを公開する（ShiftWeekPublication から呼ぶ。lock_version は変えない＝
  # 公開と同時に開いていた編集画面から、そのまま保存できる）
  def publish_draft!(now:)
    revised = published_once? && !published_matches_draft?
    update_columns(published_start_minute: start_minute, published_end_minute: end_minute, published_break_minutes: break_minutes,
                   published_at: now, revised_at: revised ? now : revised_at)
  end

  private

  # 下書きの内容を変える保存か（新規・時刻や休憩の変更・削除予定からの復活）。削除の保存では確かめない
  def changing_draft?
    new_record? || will_save_change_to_start_minute? || will_save_change_to_end_minute? ||
      will_save_change_to_break_minutes? || (will_save_change_to_removed_at? && removed_at.nil?)
  end

  def work_date_must_be_editable
    return if work_date.nil?

    range = self.class.editable_range
    return if range.cover?(work_date)

    errors.add(:work_date, :out_of_range, from: I18n.l(range.begin), to: I18n.l(range.end))
  end

  def user_must_be_active
    errors.add(:base, :inactive_user) if user && !user.active?
  end

  # 前日・翌日のシフト（日付をまたぐシフトを含む）と時間が重ならないこと
  def must_not_overlap_neighbor_shifts
    return if user_id.nil? || work_date.nil? || start_minute.nil? || end_minute.nil? || start_minute == end_minute

    neighbors = Shift.live.where(user_id: user_id, work_date: [ work_date - 1, work_date + 1 ]).where.not(id: id)
    neighbors.each do |neighbor|
      next unless neighbor.starts_at < ends_at && starts_at < neighbor.ends_at

      key = neighbor.work_date < work_date ? :overlaps_previous_day : :overlaps_next_day
      errors.add(:base, key, date: I18n.l(neighbor.work_date, format: :short_with_day), range: neighbor.range_label)
    end
  end

  def full_day_leave_must_be_acknowledged
    return if user_id.nil? || work_date.nil? || leave_acknowledged
    return unless (leave = full_day_leave)

    errors.add(:base, :on_leave, name: user&.name, leave: leave.day_label)
  end
end
