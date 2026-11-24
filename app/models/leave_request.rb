# 休暇申請（F9）。休暇の種類・期間（開始日〜終了日）・区分（全日／午前半休／午後半休）と理由を申請する。
#
# - 開始日は target_date（他の申請と同じ列）、終了日は end_date に持つ。1日だけの休暇・半休は開始日＝終了日。
# - 承認待ち・承認済み（取り消されていない）の休暇と期間が重なる申請はできない。
#   同時に送られても二重にならないよう、確認と保存を1つの書き込みトランザクションの中で行う（#submit）。
#   承認する直前にも、承認済みの休暇と重ならないかを確かめ直す（#approval_blockers）。
# - 承認されると、本人の勤怠履歴の該当日に「有給（全日）」「有給（午前半休）」のように表示される。
# - 承認済みの休暇は、開始日が明日以降なら本人が取消申請（LeaveCancellationRequest）を出せる。
#   取消申請が承認されると cancelled_at が入り、休暇として扱わなくなる（申請の状態は「承認済み」のまま）。
# - 管理者は、承認済みの休暇を開始日にかかわらず直接取り消せる（LeaveDirectCancellation）。
#   直接取り消すと cancelled_at に加えて、取り消した管理者（cancelled_by）と理由（cancellation_reason）が入る。
# - どちらの方法で取り消しても #mark_cancelled! を通る（F10 では、ここで有給の残日数を戻す）。
# - 日数（#chargeable_days）は「休日（土日・祝日。HolidayCalendar で判定）を除いた日数 × 1（全日）または 0.5（半休）」。
#   有給休暇の残日数の管理（F10）では、承認時にこの日数を減らし、取消で戻す想定。
# - 有給休暇は、期間がすべて休日で日数が0日になる場合は申請できない（承認する直前にも確かめ直す）。
class LeaveRequest < ApprovalRequest
  # 1件の申請で指定できる期間の長さ（日）。長い休暇は分けて申請する
  MAX_PERIOD_DAYS = 31
  # 申請できる日付の範囲（今日から前後1年）
  SUBMITTABLE_SPAN = 1.year

  FULL_DAY_WEIGHT = 1r
  HALF_DAY_WEIGHT = 1/2r

  enum :leave_type, { paid: "paid", special: "special", absence: "absence" }, prefix: :leave, validate: true
  enum :day_part, { full_day: "full_day", morning: "morning", afternoon: "afternoon" }, default: :full_day, validate: true

  # 休暇を直接取り消した管理者（取消申請の承認で取り消されたときは nil）
  belongs_to :cancelled_by, class_name: "User", optional: true

  has_many :cancellation_requests, -> { order(:created_at, :id) }, class_name: "LeaveCancellationRequest",
                                                                    foreign_key: :leave_request_id,
                                                                    inverse_of: :leave_request, dependent: :destroy

  # 承認済みで、取り消されていない休暇（勤怠履歴に表示し、有給の残日数から引く対象）
  scope :effective, -> { where(status: "approved", cancelled_at: nil) }
  # 新しい申請と期間が重なってはいけない休暇（承認待ち、または有効な承認済み）
  scope :blocking, -> { where(status: "pending").or(effective) }
  # from〜to の期間と1日でも重なる休暇
  scope :overlapping, ->(from, to) { where(target_date: ..to, end_date: from..) }

  before_validation :default_end_date, on: :create
  validates :end_date, presence: true
  validate :period_must_be_valid, on: :create
  validate :dates_must_be_submittable, on: :create
  validate :paid_leave_must_include_working_day, on: :create
  validate :must_not_overlap_other_leaves, on: :create

  def self.kind_label
    "休暇"
  end

  def self.detail_associations
    [ :cancellation_requests, :cancelled_by ]
  end

  def self.leave_type_label(type)
    I18n.t("enums.leave_request.leave_type.#{type}")
  end

  # 勤怠履歴などに出す短い名前（例：「有給」）
  def self.leave_type_short_label(type)
    I18n.t("enums.leave_request.leave_type_short.#{type}")
  end

  def self.day_part_label(part)
    I18n.t("enums.leave_request.day_part.#{part}")
  end

  def self.leave_type_options
    leave_types.keys.map { |type| [ leave_type_label(type), type ] }
  end

  def self.day_part_options
    day_parts.keys.map { |part| [ day_part_label(part), part ] }
  end

  # 入力画面の初期値（今日・有給休暇・全日）
  def self.build_for(user, today: Date.current)
    new(user: user, target_date: today, end_date: today, leave_type: "paid", day_part: "full_day")
  end

  def start_date
    target_date
  end

  def leave_type_label
    leave_type && self.class.leave_type_label(leave_type)
  end

  def leave_type_short_label
    leave_type && self.class.leave_type_short_label(leave_type)
  end

  def day_part_label
    day_part && self.class.day_part_label(day_part)
  end

  # 勤怠履歴に出す表示（例：「有給（全日）」「有給（午前半休）」）
  def day_label
    "#{leave_type_short_label}（#{day_part_label}）"
  end

  def half_day?
    morning? || afternoon?
  end

  def single_day?
    target_date == end_date
  end

  # 期間の日付（開始日〜終了日）
  def dates
    return [] unless target_date && end_date && end_date >= target_date

    (target_date..end_date).to_a
  end

  def covers?(date)
    target_date <= date && date <= end_date
  end

  # 日数に数える日（休日＝土日・祝日を除く）
  def working_dates
    dates.select { |date| HolidayCalendar.working_day?(date) }
  end

  # 期間のうち、日数に数えない休日（土日・祝日）
  def days_off_in_period
    dates.select { |date| HolidayCalendar.day_off?(date) }
  end

  # 1日あたりの日数（全日 1、半休 0.5）
  def day_weight
    half_day? ? HALF_DAY_WEIGHT : FULL_DAY_WEIGHT
  end

  # この休暇の日数（休日＝土日・祝日を除く。半休は 0.5日）。F10 で有給の残日数から引く日数
  def chargeable_days
    working_dates.size * day_weight
  end

  # 期間のうち range（月度など）に入る分の日数（休日を除く）
  def chargeable_days_within(range)
    working_dates.count { |date| range.cover?(date) } * day_weight
  end

  # 期間に休日（土日・祝日）が含まれるか（日数の表示で「土日・祝日を除く」と添える）
  def includes_day_off?
    dates.any? { |date| HolidayCalendar.day_off?(date) }
  end

  # 有給休暇で、期間がすべて休日のため日数が0日になるか（申請・承認できない）
  def paid_without_working_day?
    leave_paid? && dates.any? && working_dates.empty?
  end

  def target_label
    return super if end_date.nil? || single_day?

    "#{I18n.l(target_date, format: :short_with_day)}〜#{I18n.l(end_date, format: :short_with_day)}"
  end

  # 承認済みの休暇が取消申請の承認で取り消されたか
  def cancelled?
    cancelled_at.present?
  end

  # 承認済みで、取り消されていない（休暇として有効）
  def effective?
    approved? && !cancelled?
  end

  # 管理者が直接取り消したか（取消申請の承認で取り消されたときは false）
  def directly_cancelled?
    cancelled? && cancelled_by_id.present?
  end

  # 休暇を取り消す（取消申請の承認・管理者の直接取消の両方から、トランザクションの中で呼ぶ）。
  # 直接取消では by（管理者）と reason（理由）を記録する。
  # F10（有給の残日数）を実装するときは、ここで有給休暇の残日数を chargeable_days 分だけ戻す。
  def mark_cancelled!(now:, by: nil, reason: nil)
    update!(cancelled_at: now, cancelled_by: by, cancellation_reason: reason, updated_at: now)
  end

  # 管理者 admin がこの休暇を直接取り消せない理由（取り消せるなら空）。画面の出し分けと、取り消す直前の確かめに使う。
  # 自己取消のルール（有効な管理者が2人以上なら自分の休暇は取り消せない）は F8 の自己承認と同じ判断（#self_review_status）
  def direct_cancellation_blockers(admin, active_admin_count: User.active_admins.count)
    return [ I18n.t("leave_request.direct_cancellation_blockers.already_cancelled") ] if cancelled?
    return [ I18n.t("leave_request.direct_cancellation_blockers.not_approved", status: status_label) ] unless approved?
    if self_review_status(admin, active_admin_count: active_admin_count) == :forbidden
      return [ I18n.t("leave_request.direct_cancellation_blockers.own_leave", count: active_admin_count) ]
    end
    if (closed = ClosedPeriodGuard.closed_period_label(target_date, end_date))
      return [ I18n.t("leave_request.direct_cancellation_blockers.closed_period", period: closed) ]
    end

    []
  end

  # 承認待ちの取消申請（無ければ nil）
  def pending_cancellation
    cancellation_requests.find { |request| request.persisted? && request.pending? }
  end

  # 取消申請を出せるか：有効な承認済みの休暇で、開始日が明日以降（未来）で、承認待ちの取消申請が無い
  def cancellable?(today: Date.current)
    cancellation_blocker(today: today).nil?
  end

  # 取消申請を出せない理由（出せるなら nil）。I18n のキー（leave_request.cancellation_blockers.*）
  def cancellation_blocker(today: Date.current)
    if cancelled? then :already_cancelled
    elsif !approved? then :not_approved
    elsif target_date <= today then :already_started
    elsif pending_cancellation then :cancellation_pending
    end
  end

  # 申請を保存する。期間の重なりの確認と保存を1つの書き込みトランザクションで行うので、
  # 同時に送られた申請が両方とも確認を通り抜けることはない（SQLite は BEGIN IMMEDIATE で書き込みを1つずつ行う。
  # PostgreSQL などでは申請者の行をロックして順番待ちにする）。
  def submit
    saved = false
    self.class.transaction do
      User.lock.find(user_id) if user_id
      saved = save
      raise ActiveRecord::Rollback unless saved
    end
    saved
  rescue ActiveRecord::RecordNotUnique
    # 同じ開始日の承認待ちの休暇が同時に作られた（DB の一意制約）
    errors.add(:base, :overlaps_concurrent)
    false
  rescue DatabaseLockError
    errors.add(:base, :busy)
    false
  end

  def approval_result_note
    "勤怠履歴の該当日に「#{day_label}」と表示されます。"
  end

  def rejection_result_note
    "休暇は登録されません。"
  end

  def withdrawal_result_note
    "休暇は登録されません。"
  end

  # 処理済み一覧で、最後に処理した日時（直接取り消した休暇は取消の日時、それ以外は承認・却下の日時）
  def last_processed_at
    directly_cancelled? ? cancelled_at : reviewed_at
  end

  # 承認できない理由。承認する直前に、承認済みの他の休暇と期間が重ならないかを確かめ直す
  # 有給休暇は、期間がすべて休日（土日・祝日）でないことも確かめ直す（祝日の判定を入れる前に申請された休暇など）
  def approval_blockers(now: Time.current)
    blockers = []
    blockers << I18n.t("leave_request.approval_blockers.paid_days_off_only") if paid_without_working_day?
    blockers + overlapping_leaves(self.class.effective).map do |other|
      I18n.t("leave_request.approval_blockers.overlaps", leave: other.description)
    end
  end

  # 説明（例：「11/26(木)〜11/27(金) の有給休暇（全日）」）
  def description
    "#{target_label} の#{leave_type_label}（#{day_part_label}）"
  end

  # 期間中の勤務の記録（承認画面で「この期間に勤務の記録があります」と知らせる）
  def attendances_in_period
    return Attendance.none unless user && target_date && end_date

    user.attendances.where(work_date: target_date..end_date).order(:work_date)
  end

  private

  def default_end_date
    self.end_date = target_date if end_date.nil? && target_date
  end

  def period_must_be_valid
    return if target_date.nil? || end_date.nil?

    if end_date < target_date
      errors.add(:end_date, :before_start)
    elsif half_day? && !single_day?
      errors.add(:day_part, :half_day_single_date)
    elsif (end_date - target_date).to_i + 1 > MAX_PERIOD_DAYS
      errors.add(:end_date, :too_long, count: MAX_PERIOD_DAYS)
    end
  end

  def dates_must_be_submittable
    return if target_date.nil? || end_date.nil?

    today = Date.current
    errors.add(:target_date, :too_old, date: I18n.l(today - SUBMITTABLE_SPAN, format: :long)) if target_date < today - SUBMITTABLE_SPAN
    errors.add(:end_date, :too_far, date: I18n.l(today + SUBMITTABLE_SPAN, format: :long)) if end_date > today + SUBMITTABLE_SPAN
  end

  # 有給休暇は休日（土日・祝日）を日数に数えないので、休日だけの期間は申請できない（残日数が減らない休暇になる）
  def paid_leave_must_include_working_day
    return unless errors.empty? && paid_without_working_day?

    errors.add(:base, :paid_leave_days_off_only)
  end

  def must_not_overlap_other_leaves
    return if user_id.nil? || target_date.nil? || end_date.nil? || end_date < target_date

    overlapping_leaves(self.class.blocking).each do |other|
      errors.add(:base, :overlaps, leave: other.description, status: other.status_label)
    end
  end

  def overlapping_leaves(scope)
    return [] unless user_id && target_date && end_date

    scope.where(user_id: user_id).overlapping(target_date, end_date).where.not(id: id).order(:target_date).to_a
  end
end
