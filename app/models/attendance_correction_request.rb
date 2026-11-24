# 打刻修正申請（F7）。ある勤務日の正しい出勤・退勤・休憩の時刻と理由を申請する。
#
# - 申請しても勤怠記録（Attendance）は変わらない。承認されたときに申請内容どおりに更新する（F8）。
#   そのため、申請には「その日の勤怠の完成形」（出勤・退勤・すべての休憩）を持たせる。
# - 時刻は画面から「09:00」のような 時:分 と、日付（対象日＝当日／翌日）で受け取る。
#   出勤は必ず対象日（勤務日は出勤した日）。退勤・休憩は日付をまたぐ場合に「翌日」を選ぶ。
# - 退勤は必須。ただし、まだ勤務中でありうる勤務（出勤から24時間以内で、記録上も退勤していない）は空欄にできる。
class AttendanceCorrectionRequest < ApprovalRequest
  # 1件の申請で入力できる休憩の回数
  MAX_BREAKS = 10

  # 時:分（「9:00」「09:00」。<input type="time"> が秒を付けて送る「09:00:00」も受け付ける）
  TIME_FORMAT = /\A(\d{1,2}):(\d{2})(?::00)?\z/

  # 日付の選択肢：0＝対象日（当日）、1＝翌日
  DAY_VALUES = %w[0 1].freeze

  # 画面の休憩1行分の入力（そのまま再表示できるように文字列で持つ）
  BreakInput = Struct.new(:start_time, :start_day, :end_time, :end_day, keyword_init: true) do
    def blank?
      start_time.blank? && end_time.blank?
    end
  end

  # 入力を解釈した休憩1行分（number は画面の行番号）
  ParsedBreak = Struct.new(:number, :started_at, :ended_at, keyword_init: true)
  private_constant :ParsedBreak

  has_many :breaks, -> { order(:started_at, :id) }, class_name: "AttendanceCorrectionBreak",
                                                    foreign_key: :approval_request_id,
                                                    inverse_of: :correction_request, dependent: :destroy

  # 画面から受け取る入力
  attribute :clock_in_time, :string
  attribute :clock_out_time, :string
  attribute :clock_out_day, :string, default: "0"

  before_validation :apply_inputs, on: :create
  validate :target_date_must_not_be_in_future, on: :create
  validate :times_must_be_consistent, on: :create
  validate :must_differ_from_current_record, on: :create
  validate :must_not_duplicate_pending, on: :create

  def self.kind_label
    "打刻修正"
  end

  def self.detail_associations
    [ :breaks ]
  end

  # 対象日の修正申請の入力画面用。今の勤怠記録の時刻を入れておく（直したい所だけ変えればよい）
  def self.build_for(user, target_date)
    new(user: user, target_date: target_date).prefill_from_current_record
  end

  # 「09:00」→ [9, 0]。解釈できなければ nil
  def self.parse_time(value)
    match = TIME_FORMAT.match(value.to_s.unicode_normalize(:nfkc).strip)
    return unless match

    hour = match[1].to_i
    minute = match[2].to_i
    [ hour, minute ] if hour < 24 && minute < 60
  end

  # 休憩の入力（画面の行の順）。空の行も含む（行番号をエラーメッセージと合わせるため）
  def break_inputs
    @break_inputs ||= []
  end

  # 画面からの入力（{ "0" => { start_time:, ... }, "1" => ... } または配列）を受け取る
  def break_inputs=(value)
    rows = value.respond_to?(:values) ? value.values : Array(value)
    @break_inputs = rows.map do |row|
      row = row.to_h.symbolize_keys
      BreakInput.new(start_time: row[:start_time].to_s, start_day: (row[:start_day].presence || "0").to_s,
                     end_time: row[:end_time].to_s, end_day: (row[:end_day].presence || "0").to_s)
    end
  end

  # 入力欄にエラーがある休憩の行番号（1始まり）
  def invalid_break_numbers
    @invalid_break_numbers ||= Set.new
  end

  # 今の勤怠記録（無ければ nil）。承認されるまでは、申請しても変わらない
  def current_attendance
    return @current_attendance if defined?(@current_attendance)

    @current_attendance = user && target_date && user.attendances.includes(:breaks).find_by(work_date: target_date)
  end

  # 申請どおりの勤怠（保存しない）。実働時間などの計算や、今の記録との比較に使う
  def requested_attendance
    Attendance.new(user_id: user_id, work_date: target_date, clock_in_at: requested_clock_in_at,
                   clock_out_at: requested_clock_out_at).tap do |attendance|
      breaks.each { |item| attendance.breaks.build(started_at: item.started_at, ended_at: item.ended_at) }
    end
  end

  # 今の勤怠記録の時刻を入力欄に入れる
  def prefill_from_current_record
    attendance = current_attendance
    return self unless attendance

    self.clock_in_time = format_time(attendance.clock_in_at)
    if attendance.clocked_out?
      self.clock_out_time = format_time(attendance.clock_out_at)
      self.clock_out_day = day_offset(attendance.clock_out_at).to_s
    end
    self.break_inputs = attendance.breaks.map do |item|
      { start_time: format_time(item.started_at), start_day: day_offset(item.started_at).to_s,
        end_time: item.ended_at ? format_time(item.ended_at) : "", end_day: item.ended_at ? day_offset(item.ended_at).to_s : "0" }
    end
    self
  end

  # 退勤を空欄にできるか（まだ勤務中でありうる勤務）。
  # 出勤から24時間以内（ホームから退勤できる期限内）で、今の記録でも退勤していない場合だけ
  def clock_out_optional?(now: Time.current)
    return false if current_attendance&.clocked_out?

    if requested_clock_in_at
      TimeClock.clock_out_deadline_for(requested_clock_in_at) >= now
    else
      target_date == now.to_date
    end
  end

  # 申請を保存する。同時に届いた2件目（DB の一意制約で失敗）や、ロック競合もエラーとして false を返す
  def submit
    save
  rescue ActiveRecord::RecordNotUnique
    errors.add(:base, :duplicate_pending)
    false
  rescue DatabaseLockError
    errors.add(:base, :busy)
    false
  end

  # ---- 承認（F8） ----
  #
  # 承認すると、申請内容（その日の勤怠の完成形）で勤怠記録を置き換える。勤怠が無い日は新しく作る。
  # 退勤が空欄の申請（申請した時点で勤務中だった当日の勤務）は「申請した時点までの内容」として扱う：
  # - 出勤と、申請した休憩は申請どおりにする
  # - 申請した後にホームで打刻した退勤・休憩（休憩中の休憩を含む）は、そのまま残す
  # - 退勤の打刻がまだ無ければ、退勤なし（勤務中）のままになる。
  #   出勤から24時間を過ぎていれば退勤漏れになるので、承認画面で知らせる

  # 承認したときの勤怠の中身
  # kept_clock_out … 退勤を今の記録から残したか / kept_breaks … 今の記録から残す休憩（AttendanceBreak）
  ApprovalPlan = Struct.new(:clock_in_at, :clock_out_at, :kept_clock_out, :requested_breaks, :kept_breaks,
                            keyword_init: true)

  # 承認・却下した時点の記録（reviewed_record）から、比較用の勤怠（保存しない）を作る。記録が無かった日は nil
  def self.attendance_from_snapshot(snapshot, user_id:, work_date:)
    return if snapshot.blank?

    parse = ->(value) { value.presence && Time.zone.iso8601(value) }
    Attendance.new(user_id: user_id, work_date: work_date, clock_in_at: parse.call(snapshot["clock_in_at"]),
                   clock_out_at: parse.call(snapshot["clock_out_at"])).tap do |attendance|
      Array(snapshot["breaks"]).each do |started_at, ended_at|
        attendance.breaks.build(started_at: parse.call(started_at), ended_at: parse.call(ended_at))
      end
    end
  end

  # 退勤が空欄の申請（申請した時点で勤務中だった）か
  def open_ended?
    requested_clock_out_at.nil?
  end

  def approval_result_note
    return "勤怠記録を申請内容どおりに更新しました。" unless open_ended?

    "勤怠記録の出勤・休憩を申請内容どおりに更新しました（退勤は今の記録のままです）。"
  end

  # 比較表の「今の記録」の側。承認・却下済みなら、処理した時点の記録を使う（承認後も変更前と比べられるように）
  def comparison_attendance
    return current_attendance unless reviewed_at

    self.class.attendance_from_snapshot(reviewed_record, user_id: user_id, work_date: target_date)
  end

  # 申請した後に、今の記録が変わったか（ホームでの打刻など）。承認画面で注意を出す
  def current_record_changed_since_submission?
    attendance = current_attendance
    return false unless attendance && created_at

    attendance.updated_at > created_at || attendance.breaks.any? { |item| item.updated_at > created_at }
  end

  # 今の記録 current に対して承認したときの勤怠の中身
  def approval_plan(current = fresh_current_attendance)
    kept_clock_out = open_ended? && current&.clock_out_at.present? && current.clock_out_at >= created_at
    kept_breaks = open_ended? && current ? current.breaks.select { |item| item.started_at >= created_at } : []
    ApprovalPlan.new(clock_in_at: requested_clock_in_at,
                     clock_out_at: kept_clock_out ? current.clock_out_at : requested_clock_out_at,
                     kept_clock_out: kept_clock_out,
                     requested_breaks: breaks.map { |item| [ item.started_at, item.ended_at ] },
                     kept_breaks: kept_breaks)
  end

  # 承認できない理由。承認する直前の記録で、申請した後の変化（前日・翌日の勤務、ホームでの打刻、
  # 他の申請の承認）と矛盾しないかを確かめ直す
  def approval_blockers(now: Time.current)
    plan = approval_plan
    messages = blockers_for_kept_records(plan)
    messages.concat(blockers_for_neighbor_days(plan))
    messages
  end

  # 申請内容どおりに勤怠記録を更新する（承認と同じトランザクションの中で呼ぶ）
  def apply_approval!(now: Time.current)
    current = fresh_current_attendance
    plan = approval_plan(current)
    attendance = current || user.attendances.new(work_date: target_date)
    attendance.update!(clock_in_at: plan.clock_in_at, clock_out_at: plan.clock_out_at, updated_at: now)
    AttendanceBreak.where(attendance_id: attendance.id).where.not(id: plan.kept_breaks.map(&:id)).delete_all
    plan.requested_breaks.each do |started_at, ended_at|
      AttendanceBreak.create!(attendance: attendance, started_at: started_at, ended_at: ended_at)
    end
    attendance
  end

  # 処理した時点の勤怠記録（承認前の記録）。記録が無ければ nil
  def review_snapshot
    current = fresh_current_attendance
    return unless current

    { "clock_in_at" => current.clock_in_at.iso8601, "clock_out_at" => current.clock_out_at&.iso8601,
      "breaks" => current.breaks.map { |item| [ item.started_at.iso8601, item.ended_at&.iso8601 ] } }
  end

  private

  # キャッシュを使わず、DB から今の記録を読み直す（承認の直前の状態で判断するため）
  def fresh_current_attendance
    user.attendances.includes(:breaks).find_by(work_date: target_date)
  end

  # 退勤が空欄の申請で、申請後にホームで打刻された退勤を残すときの矛盾。
  # 残す退勤・休憩はどれも申請した後の時刻で、申請の出勤・休憩は申請した時刻より前なので、前後が入れ替わることは無い。
  # ただし、残す退勤は「ホームで打刻した出勤」から24時間以内なので、申請で出勤を早めると24時間を超えることがある
  def blockers_for_kept_records(plan)
    return [] unless plan.kept_clock_out && plan.clock_out_at - plan.clock_in_at > TimeClock::MAX_SHIFT_DURATION

    [ blocker(:kept_clock_out_too_long, clock_out: time_label(plan.clock_out_at)) ]
  end

  # 前日・翌日の勤務と重ならないか（申請した後に、隣の日の勤務が打刻・承認されることがある）
  def blockers_for_neighbor_days(plan)
    messages = []
    previous = user.attendances.find_by(work_date: target_date.yesterday)
    if previous&.clock_out_at && previous.clock_out_at.change(sec: 0) > plan.clock_in_at
      messages << blocker(:overlaps_previous_day, date: I18n.l(previous.work_date, format: :short_with_day),
                                                  time: I18n.l(previous.clock_out_at.in_time_zone, format: :time))
    end

    following = user.attendances.find_by(work_date: target_date.tomorrow)
    return messages unless following

    if plan.clock_out_at.nil?
      messages << blocker(:open_ended_with_next_day, date: I18n.l(following.work_date, format: :short_with_day))
    elsif following.clock_in_at.change(sec: 0) < plan.clock_out_at
      messages << blocker(:overlaps_next_day, date: I18n.l(following.work_date, format: :short_with_day),
                                              time: I18n.l(following.clock_in_at.in_time_zone, format: :time))
    end
    messages
  end

  def blocker(key, **options)
    I18n.t("attendance_correction_request.approval_blockers.#{key}", **options)
  end

  # 対象日の翌日以降なら「翌」を付けた時刻（例：「翌 02:00」）
  def time_label(time)
    time = time.in_time_zone
    prefix = time.to_date > target_date ? "翌 " : ""
    "#{prefix}#{I18n.l(time, format: :time)}"
  end

  # 入力（時:分と日付）を時刻に直す
  def apply_inputs
    @validation_now = Time.current
    @invalid_break_numbers = Set.new
    return if target_date.nil?

    self.requested_clock_in_at = time_on(clock_in_time, "0")
    self.requested_clock_out_at = time_on(clock_out_time, clock_out_day)
    @parsed_breaks = filled_break_inputs.map do |number, input|
      ParsedBreak.new(number: number, started_at: time_on(input.start_time, input.start_day),
                      ended_at: time_on(input.end_time, input.end_day))
    end
    self.breaks = @parsed_breaks.select { |item| item.started_at && item.ended_at }.map do |item|
      AttendanceCorrectionBreak.new(started_at: item.started_at, ended_at: item.ended_at)
    end
  end

  # 何か入力された休憩の行（[行番号, 入力]）
  def filled_break_inputs
    break_inputs.each.with_index(1).filter_map { |input, number| [ number, input ] unless input.blank? }
  end

  def now
    @validation_now || Time.current
  end

  # 対象日（day が "1" なら翌日）の 時:分。解釈できなければ nil
  def time_on(value, day)
    parsed = self.class.parse_time(value)
    return unless parsed && DAY_VALUES.include?(day.to_s)

    (target_date + day.to_i).in_time_zone.change(hour: parsed[0], min: parsed[1])
  end

  def format_time(time)
    time.in_time_zone.strftime("%H:%M")
  end

  # 対象日から何日後の時刻か（当日 0、翌日 1）
  def day_offset(time)
    (time.in_time_zone.to_date - target_date).to_i
  end

  def target_date_must_not_be_in_future
    return if target_date.nil?

    errors.add(:target_date, :in_future) if target_date > now.to_date
  end

  def times_must_be_consistent
    return if target_date.nil? || target_date > now.to_date

    validate_clock_in
    validate_clock_out
    validate_breaks
    validate_neighbor_attendances
  end

  def validate_clock_in
    if clock_in_time.blank?
      errors.add(:clock_in_time, :blank)
    elsif requested_clock_in_at.nil?
      errors.add(:clock_in_time, :invalid_time)
    elsif requested_clock_in_at > now
      errors.add(:clock_in_time, :in_future)
    end
  end

  def validate_clock_out
    unless DAY_VALUES.include?(clock_out_day.to_s)
      errors.add(:clock_out_day, :inclusion)
      return
    end

    if clock_out_time.blank?
      errors.add(:clock_out_time, :blank_for_past) unless clock_out_optional?(now: now)
    elsif requested_clock_out_at.nil?
      errors.add(:clock_out_time, :invalid_time)
    elsif requested_clock_in_at && requested_clock_out_at <= requested_clock_in_at
      errors.add(:clock_out_time, :not_after_clock_in)
    elsif requested_clock_in_at && requested_clock_out_at - requested_clock_in_at > TimeClock::MAX_SHIFT_DURATION
      errors.add(:clock_out_time, :too_long_shift)
    elsif requested_clock_out_at > now
      errors.add(:clock_out_time, :in_future)
    end
  end

  def validate_breaks
    errors.add(:base, :too_many_breaks, count: MAX_BREAKS) if @parsed_breaks.size > MAX_BREAKS

    valid = @parsed_breaks.select { |item| validate_break(item) }
    valid.sort_by(&:started_at).each_cons(2) do |earlier, later|
      next unless later.started_at < earlier.ended_at

      first, second = [ earlier.number, later.number ].sort
      add_break_error(:breaks_overlap, [ earlier, later ], first: first, second: second)
    end
  end

  # 休憩1行分を確かめる。問題が無ければ true
  def validate_break(item)
    input = break_inputs[item.number - 1]
    if input.start_time.blank? || input.end_time.blank?
      add_break_error(:break_incomplete, [ item ], number: item.number)
    elsif item.started_at.nil? || item.ended_at.nil?
      add_break_error(:break_invalid_time, [ item ], number: item.number)
    elsif item.ended_at <= item.started_at
      add_break_error(:break_not_after_start, [ item ], number: item.number)
    elsif item.ended_at > now
      add_break_error(:break_in_future, [ item ], number: item.number)
    elsif !within_work?(item)
      add_break_error(:break_outside_work, [ item ], number: item.number, range: work_range_label)
    else
      return true
    end
    false
  end

  # 休憩が出勤〜退勤（退勤が空欄なら今）の間か。出勤・退勤が正しく入力されていないときは判定しない
  def within_work?(item)
    return true if requested_clock_in_at.nil? || errors.include?(:clock_out_time)

    work_end = requested_clock_out_at || now
    item.started_at >= requested_clock_in_at && item.ended_at <= work_end
  end

  def work_range_label
    start = I18n.l(requested_clock_in_at, format: :time)
    return "#{start}〜現在" unless requested_clock_out_at

    next_day = requested_clock_out_at.to_date > target_date ? "翌" : ""
    "#{start}〜#{next_day}#{I18n.l(requested_clock_out_at, format: :time)}"
  end

  def add_break_error(type, items, **options)
    items.each { |item| invalid_break_numbers << item.number }
    errors.add(:base, type, **options)
  end

  # 前日・翌日の勤務と時間が重ならないか（例：前日の夜勤が 02:00 退勤なのに、01:00 出勤を申請する）
  def validate_neighbor_attendances
    return if user.nil? || requested_clock_in_at.nil? || errors.include?(:clock_in_time)

    previous = user.attendances.find_by(work_date: target_date.yesterday)
    if previous&.clock_out_at && previous.clock_out_at.change(sec: 0) > requested_clock_in_at
      errors.add(:clock_in_time, :overlaps_previous_day,
                 date: I18n.l(previous.work_date, format: :short_with_day),
                 time: I18n.l(previous.clock_out_at.in_time_zone, format: :time))
    end

    following = user.attendances.find_by(work_date: target_date.tomorrow)
    return unless following && requested_clock_out_at && !errors.include?(:clock_out_time)
    return unless following.clock_in_at.change(sec: 0) < requested_clock_out_at

    errors.add(:clock_out_time, :overlaps_next_day,
               date: I18n.l(following.work_date, format: :short_with_day),
               time: I18n.l(following.clock_in_at.in_time_zone, format: :time))
  end

  # 今の記録とまったく同じ内容の申請は受け付けない（直す所が無い）
  def must_differ_from_current_record
    return if errors.any?

    current = current_attendance
    return unless current
    return unless minute(current.clock_in_at) == requested_clock_in_at &&
                  minute(current.clock_out_at) == requested_clock_out_at

    current_breaks = current.breaks.map { |item| [ minute(item.started_at), minute(item.ended_at) ] }.sort_by(&:first)
    requested_breaks = breaks.map { |item| [ item.started_at, item.ended_at ] }.sort_by(&:first)
    errors.add(:base, :unchanged) if current_breaks == requested_breaks
  end

  def minute(time)
    time&.change(sec: 0)
  end

  # 同じ日の承認待ちの修正申請は1件まで（同時に届いた2件目は DB の一意制約で防ぎ、#submit でエラーにする）
  def must_not_duplicate_pending
    return if user_id.nil? || target_date.nil?

    errors.add(:base, :duplicate_pending) if self.class.pending.where(user_id: user_id, target_date: target_date).exists?
  end
end
