# 管理者による勤怠の直接修正（F14）。月次集計の日別の勤怠から、ある従業員のある日の出勤・退勤・休憩を直す・作る・削除する。
#
#   editor = AttendanceRecordEditor.new(user: employee, work_date: date, editor: current_user, clock_in_time: "09:00", ..., reason: "…")
#   editor.save            # 直す（勤怠が無い日は新しく作る）
#   editor.destroy_record  # 削除する
#
# - 理由は必須。修正のたびに AttendanceEdit に、誰が・いつ・修正前・修正後・理由を残す。
# - 時刻の入力の解釈と矛盾の確かめ（退勤が出勤より前・24時間を超える・未来の時刻・休憩が勤務時間の外・前日/翌日の勤務と重なる・
#   退勤を空欄にできるのは出勤から24時間以内の勤務中だけ、など）は、打刻修正申請（F7）と同じ規則を使う
#   （AttendanceCorrectionRequest を保存せずに組み立てて確かめる。申請と管理者の修正で、受け付ける内容が食い違わないように）。
# - 直せない日
#   - 締め済み（F14）の月度の日（ClosedPeriodGuard）。未来の日。
#   - 自分の勤怠で、有効な管理者が2人以上いる（F8 の自己承認ルールと同じ。他の管理者が直す）
# - 画面を開いた後に記録が変わっていたら（本人の打刻・申請の承認・他の管理者の修正）、上書きせずにエラーにする
#   （画面を開いた時点の記録の印 record_token と、保存する直前の記録を比べる）。
# - 確かめと書き込みは1つの書き込みトランザクションの中で行う（締め・打刻・承認と同時に届いても食い違わない）。
class AttendanceRecordEditor
  include ActiveModel::Model
  include ActiveModel::Attributes

  NO_RECORD_TOKEN = "none".freeze

  attribute :clock_in_time, :string
  attribute :clock_out_time, :string
  attribute :clock_out_day, :string, default: "0"
  attribute :reason, :string
  attribute :record_token, :string

  attr_reader :user, :work_date, :editor, :edit

  def self.token_for(attendance)
    attendance ? Digest::SHA256.hexdigest(AttendanceEdit.record_of(attendance).to_json) : NO_RECORD_TOKEN
  end

  def initialize(user:, work_date:, editor:, **attributes)
    @user = user
    @work_date = work_date
    @editor = editor
    @break_inputs = nil
    super(**attributes)
  end

  # 入力欄に今の記録を入れる（直したい所だけ変えればよい）
  def prefill
    source = AttendanceCorrectionRequest.build_for(user, work_date)
    self.clock_in_time = source.clock_in_time
    self.clock_out_time = source.clock_out_time
    self.clock_out_day = source.clock_out_day
    self.break_inputs = source.break_inputs.map(&:to_h)
    self.record_token = self.class.token_for(current_attendance)
    self
  end

  def break_inputs
    inputs.break_inputs
  end

  def break_inputs=(value)
    @break_inputs = value
    @inputs = nil
  end

  def invalid_break_numbers
    inputs.invalid_break_numbers
  end

  # 今の記録（無ければ nil）
  def current_attendance
    return @current_attendance if defined?(@current_attendance)

    @current_attendance = user.attendances.includes(:breaks).find_by(work_date: work_date)
  end

  # 退勤を空欄にできるか（出勤から24時間以内で、まだ退勤していない勤務）
  def clock_out_optional?(now: Time.current)
    inputs.clock_out_optional?(now: now)
  end

  # この日を直せない理由（直せるなら空）。画面の出し分けと、保存する直前の確かめの両方で使う
  def blockers(today: Date.current, active_admin_count: User.active_admins.count)
    return [ "管理者の権限が無いため、勤怠を直せません。" ] unless User.active_admins.exists?(id: editor.id)
    return [ "未来の日付（#{date_label}）の勤怠は直せません。" ] if work_date > today
    if (closing = ClosedPeriodGuard.closing_overlapping(work_date))
      return [ "#{date_label} は#{ClosedPeriodGuard.describe(closing)}に含まれるため、直せません。直す場合は、先に締めを解除してください。" ]
    end
    if user.id == editor.id && active_admin_count >= 2
      return [ "ご自身の勤怠は他の管理者が直します（有効な管理者が#{active_admin_count}名いるため、ご自身では直せません）。" ]
    end

    []
  end

  # 直す（勤怠が無い日は作る）。成功すれば true（#edit に残した履歴）
  def save(now: Time.current)
    self.reason = reason.to_s.strip
    run_in_transaction do
      current = prepare!(now)
      check_inputs!
      before = AttendanceEdit.record_of(current)
      attendance = current || user.attendances.new(work_date: work_date)
      attendance.update!(clock_in_at: inputs.requested_clock_in_at, clock_out_at: inputs.requested_clock_out_at, updated_at: now)
      AttendanceBreak.where(attendance_id: attendance.id).delete_all
      inputs.breaks.each do |item|
        AttendanceBreak.create!(attendance: attendance, started_at: item.started_at, ended_at: item.ended_at)
      end
      attendance = Attendance.includes(:breaks).find(attendance.id)
      record!(current ? "updated" : "created", before, AttendanceEdit.record_of(attendance), now)
    end.tap do |saved|
      # 直した勤怠が確定した後に、残業の警告を判定する。失敗しても修正は取り消さない（F16）
      OvertimeAlert.check(user, date: work_date, now: now) if saved
    end
  end

  # 削除する。成功すれば true
  def destroy_record(now: Time.current)
    self.reason = reason.to_s.strip
    run_in_transaction do
      current = prepare!(now)
      fail!("この日には削除する勤怠がありません。") unless current
      check_reason!
      before = AttendanceEdit.record_of(current)
      current.destroy!
      record!("deleted", before, nil, now)
    end
  end

  private

  def date_label
    I18n.l(work_date, format: :short_with_day)
  end

  # 入力を解釈して確かめる、保存しない打刻修正申請（AttendanceCorrectionRequest と同じ規則で確かめるため）
  def inputs
    @inputs ||= AttendanceCorrectionRequest.new(user: user, target_date: work_date, clock_in_time: clock_in_time,
                                                clock_out_time: clock_out_time, clock_out_day: clock_out_day,
                                                reason: reason.presence || "-").tap do |request|
      request.break_inputs = @break_inputs || []
    end
  end

  class Refused < StandardError; end
  private_constant :Refused

  def run_in_transaction
    saved = false
    Attendance.transaction do
      yield
      saved = true
    rescue Refused
      raise ActiveRecord::Rollback
    end
    reset_current
    saved
  rescue ActiveRecord::RecordInvalid => error
    reset_current
    errors.add(:base, "勤怠を保存できませんでした（#{error.record.errors.full_messages.to_sentence}）。画面を再読み込みして、今の記録を確認してください。")
    false
  rescue ActiveRecord::RecordNotUnique
    reset_current
    errors.add(:base, "同時に別の勤怠の記録が作られたため、保存できませんでした。画面を再読み込みして、今の記録を確認してください。")
    false
  rescue DatabaseLockError
    reset_current
    errors.add(:base, DatabaseLockError::MESSAGE)
    false
  end

  # 直せるか（権限・締め・自分の勤怠）と、画面を開いた後に記録が変わっていないかを、トランザクションの中で確かめる
  def prepare!(now)
    blockers(today: now.to_date).each { |message| errors.add(:base, message) }
    raise Refused if errors.any?

    reset_current
    current = current_attendance
    if record_token.present? && record_token != self.class.token_for(current)
      fail!("画面を開いた後に、この日の記録が変わりました（本人の打刻・申請の承認・他の管理者の修正など）。今の記録を確かめてから、もう一度直してください。")
    end
    current
  end

  def check_inputs!
    @inputs = nil
    unless inputs.valid?(:create)
      inputs.errors.each do |error|
        next if %i[duplicate_pending closed_period].include?(error.type)

        if error.type == :unchanged
          errors.add(:base, "今の記録と同じ内容です。直す所を変えてから保存してください。")
        elsif error.attribute != :reason
          errors.add(error.attribute, error.message)
        end
      end
    end
    check_reason!
    raise Refused if errors.any?
  end

  def check_reason!
    if reason.blank?
      errors.add(:reason, :blank)
    elsif reason.length > ApprovalRequest::REASON_MAX_LENGTH
      errors.add(:reason, :too_long, count: ApprovalRequest::REASON_MAX_LENGTH)
    end
    raise Refused if errors.any?
  end

  def fail!(message)
    errors.add(:base, message)
    raise Refused
  end

  def record!(operation, before, after, now)
    @edit = AttendanceEdit.create!(user: user, work_date: work_date, editor: editor, operation: operation, reason: reason,
                                   before_record: before, after_record: after, created_at: now, updated_at: now)
  end

  def reset_current
    remove_instance_variable(:@current_attendance) if defined?(@current_attendance)
  end
end
