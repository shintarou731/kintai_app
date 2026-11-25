# 誤って登録した有給休暇の付与の削除（F10）。
#
#   removal = PaidLeaveGrantRemoval.new(grant: grant, admin: current_user, reason: "日数を誤って登録したため")
#   removal.save # => true / false（errors に理由）
#
# - 理由は必須。空なら削除しない（付与はそのまま、記録も作らない）。
# - 行は消さず、削除した管理者・日時・理由を付与に記録する（PaidLeaveGrant#mark_removed!）。付与の内容（付与日・日数・有効期限）は
#   そのまま残るので、管理者の付与の画面と本人の「休暇」画面の履歴に「付与の削除」として出せる。
# - 削除した付与は残日数・申請できる残りの計算に使わない（PaidLeaveGrant.kept）。
# - 削除すると、承認済み・承認待ちの有給休暇が付与で賄えなくなる（不足が増える）場合は削除できない。
#   先に休暇を取り消す・却下するか、正しい付与を登録してから削除する。この場合も記録は作らない。
# - 従業員の行をロックしてから付与を読み直して確かめるので、同じ人の有給の申請・承認や、同じ付与の二重の削除と同時に届いても、
#   確かめが入れ違わない（SQLite は BEGIN IMMEDIATE で書き込みを1つずつ行う）。後から届いた二重の削除はエラーになる。
# - 本人への通知は送らない（仕様に定めが無いため。本人は「休暇」画面の履歴で確かめられる）。
class PaidLeaveGrantRemoval
  include ActiveModel::Model
  include ActiveModel::Attributes

  REASON_MAX_LENGTH = ApprovalRequest::REASON_MAX_LENGTH

  attribute :reason, :string

  attr_reader :grant, :admin

  validates :reason, presence: true, length: { maximum: REASON_MAX_LENGTH }

  def initialize(grant:, admin:, **attributes)
    @grant = grant
    @admin = admin
    super(**attributes)
  end

  # 削除すると賄えなくなる有給の日数（0 なら削除できる）。画面で前もって知らせるために使う
  def shortage_increase(today: Date.current)
    grants = PaidLeaveGrant.kept.where(user_id: grant.user_id).to_a
    leaves = LeaveRequest.leave_paid.blocking.where(user_id: grant.user_id).to_a
    before = PaidLeaveLedger.new(grants: grants, leaves: leaves, today: today)
    after = PaidLeaveLedger.new(grants: grants.reject { |item| item.id == grant.id }, leaves: leaves, today: today)
    PaidLeaveLedger.days(after.uncovered_half_days - before.uncovered_half_days)
  end

  def save(now: Time.current)
    self.reason = reason.to_s.strip.presence
    return false unless valid?

    removed = false
    PaidLeaveGrant.transaction do
      User.lock.find(grant.user_id)
      current = PaidLeaveGrant.lock.find_by(id: grant.id, user_id: grant.user_id)
      if current.nil? || current.removed?
        errors.add(:base, "この付与はすでに削除されています。画面を再読み込みして、今の状態を確認してください。")
        raise ActiveRecord::Rollback
      end
      unless User.active_admins.exists?(id: admin.id)
        errors.add(:base, "管理者の権限が無いため、付与を削除できません。")
        raise ActiveRecord::Rollback
      end

      @grant = current
      if (increase = shortage_increase(today: now.to_date)).positive?
        errors.add(:base, self.class.blocked_message(increase))
        raise ActiveRecord::Rollback
      end

      current.mark_removed!(by: admin, reason: reason, now: now)
      removed = true
    end
    grant.reload
    removed
  rescue DatabaseLockError
    errors.add(:base, DatabaseLockError::MESSAGE)
    false
  end

  def self.blocked_message(increase)
    "この付与を削除すると、承認済み・承認待ちの有給休暇のうち #{LeaveRequest.format_days(increase)} が付与で賄えなくなるため、削除できません。" \
      "先に該当する有給休暇を取り消す（承認待ちなら却下する）か、正しい付与を登録してから削除してください。"
  end
end
