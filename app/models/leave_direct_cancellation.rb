# 管理者による承認済み休暇の直接取消（F9）。取消申請・承認の手続きを経ずに、操作した時点で取り消す。
#
#   cancellation = LeaveDirectCancellation.new(leave_request: leave, admin: current_user, reason: "本人から電話で依頼があったため")
#   cancellation.save # => true / false（errors に理由）
#
# - 開始日が当日・過去・未来のどの休暇も取り消せる。理由は必須。
# - 取り消した管理者・日時・理由を休暇に記録する（LeaveRequest#mark_cancelled!）。
# - 承認待ちの取消申請があれば、同じトランザクションで「承認済み（直接取消で処理済み）」にする
#   （LeaveCancellationRequest#close_by_direct_cancellation!）。承認待ちの一覧から消え、二重に処理されない。
# - 取り消せない場合（LeaveRequest#direct_cancellation_blockers）
#   - 承認済みでない・すでに取り消されている
#   - 自分の休暇で、有効な管理者が2人以上いる（F8 の自己承認ルールと同じ）
#   - 締め済み（F14）の月度に1日でもかかる（ClosedPeriodGuard。F14 の実装までは該当なし）
# - トランザクションの中で休暇を読み直してから判断する（SQLite は BEGIN IMMEDIATE で書き込みを1つずつ行う。
#   PostgreSQL などでは休暇の行をロックする）。取消申請の承認や、別の管理者の直接取消と同時に届いても、
#   取り消されるのは1回だけで、後から届いた方はエラーになる。管理者の人数もトランザクションの中で数え直す。
class LeaveDirectCancellation
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :reason, :string

  attr_reader :leave_request, :admin, :closed_cancellation_requests

  validates :reason, presence: true, length: { maximum: ApprovalRequest::REASON_MAX_LENGTH }

  def initialize(leave_request:, admin:, **attributes)
    @leave_request = leave_request
    @admin = admin
    @closed_cancellation_requests = []
    super(**attributes)
  end

  # 取り消す。成功すれば true（leave_request は取消後の休暇になる）
  def save(now: Time.current)
    self.reason = reason.to_s.strip.presence
    return false unless valid?

    saved = false
    LeaveRequest.transaction do
      leave = LeaveRequest.lock.find(leave_request.id)
      refusals = refusal_reasons(leave)
      if refusals.any?
        refusals.each { |message| errors.add(:base, message) }
        raise ActiveRecord::Rollback
      end

      leave.mark_cancelled!(now: now, by: admin, reason: reason)
      # 承認待ちの取消申請を読み直して（行をロックして）から処理済みにする
      @closed_cancellation_requests = LeaveCancellationRequest.lock.where(leave_request_id: leave.id, status: "pending").select do |request|
        request.close_by_direct_cancellation!(admin: admin, now: now)
      end
      @leave_request = leave
      saved = true
    end
    if saved
      # 取消が確定した後に、休暇の本人へ通知する（通知が作れなくても取消は取り消さない。F16）
      Notifier.leave_cancelled_by_admin(leave_request, admin: admin, closed_requests: closed_cancellation_requests)
    else
      leave_request.reload
    end
    saved
  rescue ActiveRecord::RecordInvalid => error
    fail_with("休暇を取り消せませんでした（#{error.record.errors.full_messages.to_sentence}）。画面を再読み込みして、今の状態を確認してください。")
  rescue DatabaseLockError
    fail_with(DatabaseLockError::MESSAGE)
  end

  private

  # 取り消せない理由（その時点の DB の状態で判断する）
  def refusal_reasons(leave)
    return [ "管理者の権限が無いため、休暇を取り消せません。" ] unless User.active_admins.exists?(id: admin.id)

    leave.direct_cancellation_blockers(admin)
  end

  def fail_with(message)
    errors.add(:base, message)
    leave_request.reload
    false
  end
end
