# 管理者による申請の承認・却下（F8）。
#
#   review = ApprovalReview.new(approval_request: request, reviewer: current_user, decision: "approve", comment: "")
#   review.save # => true / false（errors に理由）
#
# - 却下するときはコメントが必須。承認のコメントは任意。
# - 承認すると、申請の種類ごとの処理（打刻修正なら勤怠記録の更新）を、状態の変更と同じトランザクションで行う。
#   どちらかが失敗すれば両方とも取り消される（申請は承認待ちのまま、勤怠も変わらない）。
# - トランザクションの中で申請を読み直してから判断するので、二重承認や、取り下げ・他の管理者の処理と
#   同時に届いても、処理されるのは最初の1回だけ（SQLite は BEGIN IMMEDIATE で書き込みを1つずつ行う。
#   PostgreSQL などでは申請の行をロックする）。
# - 自己承認ルール：有効な管理者が2人以上なら、自分の申請は承認・却下できない（ApprovalRequest#self_review_status）。
#   人数もトランザクションの中で数え直すので、管理者の無効化・追加と同時に届いても判断がずれない。
class ApprovalReview
  include ActiveModel::Model
  include ActiveModel::Attributes

  DECISIONS = %w[approve reject].freeze

  attribute :decision, :string
  attribute :comment, :string

  attr_reader :approval_request, :reviewer

  validates :decision, inclusion: { in: DECISIONS }
  validates :comment, length: { maximum: ApprovalRequest::REVIEW_COMMENT_MAX_LENGTH }
  validate :comment_required_for_rejection

  def initialize(approval_request:, reviewer:, **attributes)
    @approval_request = approval_request
    @reviewer = reviewer
    super(**attributes)
  end

  def approve?
    decision == "approve"
  end

  def reject?
    decision == "reject"
  end

  # 承認・却下する。成功すれば true（approval_request は処理後の申請になる）
  def save(now: Time.current)
    self.comment = comment.to_s.strip.presence
    return false unless valid?

    saved = false
    ApprovalRequest.transaction do
      request = ApprovalRequest.lock.find(approval_request.id)
      refusals = refusal_reasons(request, now)
      if refusals.any?
        refusals.each { |message| errors.add(:base, message) }
        raise ActiveRecord::Rollback
      end

      request.update!(status: approve? ? "approved" : "rejected", reviewer: reviewer, reviewed_at: now,
                      review_comment: comment, reviewed_record: request.review_snapshot)
      request.apply_approval!(now: now) if approve?
      @approval_request = request
      saved = true
    end
    approval_request.reload unless saved
    saved
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    fail_with("勤怠記録を更新できなかったため、承認できませんでした（#{error_detail(error)}）。画面を再読み込みして、今の記録を確認してください。")
  rescue DatabaseLockError
    fail_with(DatabaseLockError::MESSAGE)
  end

  private

  def comment_required_for_rejection
    errors.add(:comment, :blank_for_rejection) if reject? && comment.blank?
  end

  # 処理できない理由（その時点の DB の状態で判断する）
  def refusal_reasons(request, now)
    return [ "管理者の権限が無いため、承認・却下できません。" ] unless User.active_admins.exists?(id: reviewer.id)
    return [ not_pending_message(request) ] unless request.pending?

    if request.self_review_status(reviewer) == :forbidden
      return [ "ご自身の申請は他の管理者が処理します（有効な管理者が2名以上いるため、ご自身では承認・却下できません）。" ]
    end

    approve? ? request.approval_blockers(now: now) : []
  end

  def not_pending_message(request)
    if request.withdrawn?
      "この申請は申請者が取り下げたため、承認・却下できません。"
    else
      by = request.reviewer ? "#{request.reviewer.name} さんが " : ""
      at = request.reviewed_at ? "#{I18n.l(request.reviewed_at, format: :short)} に" : ""
      "この申請はすでに#{by}#{at}処理済みです（#{request.status_label}）。"
    end
  end

  def error_detail(error)
    error.respond_to?(:record) && error.record ? error.record.errors.full_messages.to_sentence : "同時に別の記録が作られました"
  end

  def fail_with(message)
    errors.add(:base, message)
    approval_request.reload
    false
  end
end
