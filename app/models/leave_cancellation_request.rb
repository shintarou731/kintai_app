# 休暇の取消申請（F9）。承認済みの休暇のうち、開始日が明日以降（未来）のものを、本人が取り消したいときに出す。
#
# - 対象日（target_date）は、取り消す休暇の開始日（承認画面・申請一覧の並びと表示に使う）。
# - 管理者が承認すると、休暇の cancelled_at が入り、勤怠履歴に表示されなくなる（F10 では有給の残日数が戻る）。
#   却下・取り下げなら、休暇は有効のまま。
# - 開始日が今日以前（当日・過去・期間の途中）の休暇には出せない。休みを取ったかどうかを後から変える扱いになり、
#   F12 の予実比較や F14 の締めと食い違うため（取り消したい場合は管理者に依頼し、管理者が直接取り消す。LeaveDirectCancellation）。
# - 1つの休暇に、承認待ちの取消申請は1件まで（同時に送られても DB の一意制約で1件に絞る）。
# - 承認待ちのうちに管理者が休暇を直接取り消した（LeaveDirectCancellation）ときは、取消申請の目的は果たされたので、
#   その管理者の処理として「承認済み」にする（#close_by_direct_cancellation!）。承認待ちの一覧から消え、二重に処理されない。
#   reviewed_record に { "closed_by" => "direct_cancellation" } を入れて、通常の承認と区別して表示する。
class LeaveCancellationRequest < ApprovalRequest
  CLOSED_BY_DIRECT_CANCELLATION = "direct_cancellation".freeze

  belongs_to :leave_request, inverse_of: :cancellation_requests

  before_validation :copy_target_date, on: :create
  validate :leave_must_be_cancellable, on: :create

  def self.kind_label
    "休暇取消"
  end

  def self.detail_associations
    [ :leave_request ]
  end

  def target_label
    leave_request ? leave_request.target_label : super
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

  def approval_result_note
    "休暇を取り消しました（勤怠履歴の表示も消えます）。"
  end

  def rejection_result_note
    "休暇は取り消されず、有効のままです。"
  end

  def withdrawal_result_note
    "休暇は有効のままです。"
  end

  # 承認できない理由。承認する直前に、休暇がまだ有効か（他の取消で取り消されていないか）を確かめ直す
  def approval_blockers(now: Time.current)
    leave = LeaveRequest.find(leave_request_id)
    return [ I18n.t("leave_cancellation_request.approval_blockers.already_cancelled") ] if leave.cancelled?
    return [ I18n.t("leave_cancellation_request.approval_blockers.not_approved", status: leave.status_label) ] unless leave.approved?

    []
  end

  # 休暇を取り消す（承認と同じトランザクションの中で呼ぶ。approval_blockers で有効なことを確かめた後）
  def apply_approval!(now: Time.current)
    leave = LeaveRequest.lock.find(leave_request_id)
    # ロックを取った後にも確かめる（承認の確かめの後で、管理者の直接取消が先に終わっていることがある）
    if leave.cancelled?
      errors.add(:base, I18n.t("leave_cancellation_request.approval_blockers.already_cancelled"))
      raise ActiveRecord::RecordInvalid, self
    end
    leave.mark_cancelled!(now: now)
    self.leave_request = leave
  end

  # 管理者が休暇を直接取り消したので、この承認待ちの取消申請を処理済み（承認済み）にする。
  # 直接取消と同じトランザクションの中で呼ぶ。承認待ちでなければ何もしない（false）
  def close_by_direct_cancellation!(admin:, now:)
    return false unless pending?

    update!(status: "approved", reviewer: admin, reviewed_at: now,
            review_comment: I18n.t("leave_cancellation_request.closed_by_direct_cancellation_comment", name: admin.name),
            reviewed_record: { "closed_by" => CLOSED_BY_DIRECT_CANCELLATION })
    true
  end

  # 管理者の直接取消によって処理済みになったか
  def closed_by_direct_cancellation?
    reviewed_record.is_a?(Hash) && reviewed_record["closed_by"] == CLOSED_BY_DIRECT_CANCELLATION
  end

  # 取消の対象日（開始日）を過ぎたか。申請した時点では未来でも、処理が遅れて過ぎることがある
  def target_passed?(today: Date.current)
    target_date <= today
  end

  private

  def copy_target_date
    self.target_date = leave_request&.target_date
  end

  # 申請した時点の DB の状態で確かめる（画面を開いた後に、承認・取消などで休暇が変わっていることがある）
  def leave_must_be_cancellable
    return if leave_request_id.nil?

    leave = LeaveRequest.includes(:cancellation_requests).find_by(id: leave_request_id)
    if leave.nil? || leave.user_id != user_id
      errors.add(:base, :not_own_leave)
    elsif (blocker = leave.cancellation_blocker)
      errors.add(:base, blocker)
    end
  end
end
