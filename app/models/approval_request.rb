# 従業員が出す「申請」の共通部分。申請の種類はサブクラス（STI の type 列）で区別する。
# - AttendanceCorrectionRequest … 打刻修正申請（F7）
# - LeaveRequest                … 休暇申請（F9）
# - LeaveCancellationRequest    … 承認済みの休暇の取消申請（F9）
# どの種類も同じ「申請」一覧・承認画面（F8）に並ぶ。
# 種類ごとの承認時の処理は、サブクラスで approval_blockers / apply_approval! / review_snapshot を定める。
#
# 状態
# - pending   … 承認待ち（本人が取り下げられる。管理者が承認・却下できる）
# - approved  … 承認済み（reviewer・reviewed_at に処理した管理者と日時）
# - rejected  … 却下（同上。review_comment に却下の理由）
# - withdrawn … 取り下げ（本人が承認待ちのうちに取り下げた）
class ApprovalRequest < ApplicationRecord
  REASON_MAX_LENGTH = 500
  REVIEW_COMMENT_MAX_LENGTH = 500
  PROCESSED_STATUSES = %w[approved rejected].freeze

  belongs_to :user
  belongs_to :reviewer, class_name: "User", optional: true

  # 承認・却下した時点の勤怠記録など（種類ごとの形。review_snapshot を参照）
  serialize :reviewed_record, coder: JSON

  enum :status, { pending: "pending", approved: "approved", rejected: "rejected", withdrawn: "withdrawn" },
       default: :pending, validate: true

  normalizes :reason, with: ->(reason) { reason.strip }

  validates :target_date, presence: true
  validates :reason, presence: true, length: { maximum: REASON_MAX_LENGTH }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  # 処理済み（承認・却下）
  scope :processed, -> { where(status: PROCESSED_STATUSES) }
  # 承認画面の承認待ち：古い申請から順に処理できるよう、申請日の古い順
  scope :oldest_first, -> { order(created_at: :asc, id: :asc) }
  # 承認画面の処理済み：最後に処理した日時の新しい順。管理者が直接取り消した休暇は、取り消した日時で並べる
  scope :recently_processed_first, lambda {
    order(Arel.sql("COALESCE(CASE WHEN cancelled_by_id IS NOT NULL THEN cancelled_at END, reviewed_at) DESC"), id: :desc)
  }

  # 管理者 admin が処理できる承認待ちの申請（ナビの件数バッジ）。
  # 有効な管理者が2人以上なら、自分の申請は他の管理者が処理するので数えない（自己承認ルール。#self_review_status と同じ判断）
  def self.actionable_by(admin, active_admin_count: User.active_admins.count)
    requests = pending
    active_admin_count >= 2 ? requests.where.not(user_id: admin.id) : requests
  end

  # 申請の種類の表示名（例：「打刻修正」）。サブクラスで定める
  def self.kind_label
    raise NotImplementedError
  end

  def self.status_label(status)
    I18n.t("enums.approval_request.status.#{status}")
  end

  # 状態の選択肢などに使う（表示名, 値）
  def self.status_options
    statuses.keys.map { |status| [ status_label(status), status ] }
  end

  # 一覧の「内容」に使う関連（種類ごと）。サブクラスで定める
  def self.detail_associations
    []
  end

  # 種類の混ざった申請の一覧について、種類ごとの関連をまとめて読み込む
  def self.preload_details(requests)
    requests.group_by(&:class).each do |klass, records|
      associations = klass.detail_associations
      ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call if associations.any?
    end
  end

  def kind_label
    self.class.kind_label
  end

  # 対象日の表示（例：「11/20(金)」）。休暇申請では期間（「11/26(木)〜11/27(金)」）になる
  def target_label
    I18n.l(target_date, format: :short_with_day)
  end

  # 承認したときの結果の説明（承認後のメッセージに添える）。種類ごとにサブクラスで定める
  def approval_result_note
    ""
  end

  # 却下したときの結果の説明（却下後のメッセージに添える）
  def rejection_result_note
    "勤怠記録は変わりません。"
  end

  # 本人が取り下げたときの結果の説明
  def withdrawal_result_note
    "勤怠記録は変わりません。"
  end

  def status_label
    self.class.status_label(status)
  end

  # 処理済み一覧で、最後に処理した日時（種類ごとに変わる場合はサブクラスで定める）
  def last_processed_at
    reviewed_at
  end

  # 承認・却下済みか
  def processed?
    PROCESSED_STATUSES.include?(status)
  end

  # 本人が取り下げられるか（承認待ちのときだけ）
  def withdrawable?
    pending?
  end

  # 取り下げる。承認待ちのときだけ取り下げられ、成功すれば true。
  # 「承認待ちであること」を条件に1回の UPDATE で書き込むので、承認・却下と同時に届いても、
  # 承認・却下済みの申請が取り下げに変わることはない。
  def withdraw(now: Time.current)
    updated = ApprovalRequest.where(id: id, status: "pending")
                             .update_all(status: "withdrawn", withdrawn_at: now, updated_at: now)
    reload
    updated == 1
  end

  # 管理者 admin から見た、自分の申請の扱い（F8 の自己承認ルール）
  # - :not_own   … 他の人の申請（通常どおり承認・却下できる）
  # - :allowed   … 自分の申請だが、有効な管理者が1人だけなので承認・却下できる
  # - :forbidden … 自分の申請で、有効な管理者が2人以上いるので承認・却下できない（他の管理者が処理する）
  # 有効な管理者＝役割が管理者で、状態が有効なユーザー（無効化された管理者・従業員は数えない）
  def self_review_status(admin, active_admin_count: User.active_admins.count)
    return :not_own unless user_id == admin.id

    active_admin_count >= 2 ? :forbidden : :allowed
  end

  # 承認・却下の直前に、承認の判断に使う関連する行をロックする（ApprovalReview のトランザクションの中で呼ぶ）。種類ごとにサブクラスで定める
  def lock_for_review!
  end

  # 承認できない理由（無ければ空）。承認する直前に、その時点のデータで確かめる。種類ごとにサブクラスで定める
  def approval_blockers(now: Time.current)
    []
  end

  # 承認したときの処理（勤怠記録の更新など）。承認と同じトランザクションの中で呼ぶ。種類ごとにサブクラスで定める
  def apply_approval!(now: Time.current)
  end

  # 承認・却下した時点の記録（reviewed_record に保存する）。種類ごとにサブクラスで定める
  def review_snapshot
    nil
  end
end
