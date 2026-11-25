# ある従業員の有給休暇の状況（F10）。「休暇」画面・ホーム画面・従業員一覧・付与の画面で表示する値をまとめる。
#
# - 残日数（balance）は、承認済みで取り消されていない有給休暇だけを消化に数える（PaidLeaveLedger）。
# - 申請できる残り（requestable）は、承認待ちの有給休暇も消化に数えた残日数（申請時の確かめと同じ数え方）。
# - 当年度は 4月1日〜翌年3月31日（日本の会計年度。FISCAL_YEAR_START_MONTH）。
#   当年度の取得日数は、当年度の日付に当たる承認済み（取り消されていない）の有給休暇の日数（休日を除く・半休は0.5日）。
#   今日より後の日付の分は「取得予定」として内訳に出し、合計には含める（年5日の判定にも使う）。
# - 年5日の印（annual_target_alert?）は、当年度に使える付与がある人だけに付ける。「付与が無い」とは、
#   使える期間（付与日〜有効期限）が当年度と1日も重ならない付与しか無いこと（付与が0件を含む）。役割にかかわらず同じ基準。
# - 削除した付与（PaidLeaveGrant#removed?）は、残日数・申請できる残り・年5日の対象の判定に使わない。
#   履歴には「付与の削除」として出す（removed_grants）。
class PaidLeaveAccount
  FISCAL_YEAR_START_MONTH = 4
  # 年5日の取得の目安（これ未満なら従業員一覧で印を付ける）
  ANNUAL_TARGET_DAYS = 5

  # 履歴の1行
  # kind … :grant（付与）/ :usage（取得）/ :cancelled（取得の取消）/ :lapse（失効）/ :pending（承認待ち）/ :removal（付与の削除）
  # days … 残日数の増減（付与・取消は +、取得・失効は −、承認待ちは 0 ではなく申請の日数を負で持ち、pending? で区別する）
  #        付与の削除は、削除した付与の日数（+）を持つ。削除した付与は残日数に数えないので、表示では打ち消し線にする
  HistoryEntry = Data.define(:date, :kind, :days, :record, :usage) do
    def grant?
      kind == :grant
    end

    def pending?
      kind == :pending
    end
  end

  attr_reader :user, :today

  # 従業員一覧など、複数人の状況をまとめて作る（付与と休暇を2回の問い合わせで読む）
  def self.for_users(users, today: Date.current)
    ids = users.map(&:id)
    grants = PaidLeaveGrant.kept.where(user_id: ids).to_a.group_by(&:user_id)
    leaves = LeaveRequest.leave_paid.where(user_id: ids).where(status: %w[pending approved]).to_a.group_by(&:user_id)
    users.to_h do |user|
      [ user.id, new(user, today: today, grants: grants.fetch(user.id, []), leaves: leaves.fetch(user.id, [])) ]
    end
  end

  # 当年度（4/1〜翌3/31）の期間
  def self.fiscal_year_range(today)
    year = today.month >= FISCAL_YEAR_START_MONTH ? today.year : today.year - 1
    Date.new(year, FISCAL_YEAR_START_MONTH, 1)..Date.new(year + 1, FISCAL_YEAR_START_MONTH, 1).prev_day
  end

  # grants … 削除されていない付与（省略すると user.paid_leave_grants）。削除した付与が混ざっていても数えない
  # removed_grants … 削除した付与（履歴に出す。省略すると、履歴を作るときに読む）
  def initialize(user, today: Date.current, grants: nil, leaves: nil, removed_grants: nil)
    @user = user
    @today = today
    @grants = (grants || user.paid_leave_grants.to_a).reject(&:removed?)
    @removed_grants = removed_grants
    # 承認待ち・承認済み（取消済みを含む）の有給休暇
    @leaves = leaves || user.leave_requests.leave_paid.where(status: %w[pending approved]).to_a
  end

  attr_reader :grants

  def effective_leaves
    @effective_leaves ||= @leaves.select(&:effective?)
  end

  def pending_leaves
    @pending_leaves ||= @leaves.select(&:pending?)
  end

  def cancelled_leaves
    @cancelled_leaves ||= @leaves.select { |leave| leave.approved? && leave.cancelled? }
  end

  # 承認済みの有給だけを数えた台帳
  def ledger
    @ledger ||= PaidLeaveLedger.new(grants: grants, leaves: effective_leaves, today: today)
  end

  # 承認待ちも数えた台帳（申請できる残り）
  def requestable_ledger
    @requestable_ledger ||= PaidLeaveLedger.new(grants: grants, leaves: effective_leaves + pending_leaves, today: today)
  end

  # 残り（承認済みの有給を引いた残日数）
  def balance
    ledger.balance
  end

  # 承認待ちの有給の日数
  def pending_days
    pending_leaves.sum(&:chargeable_days)
  end

  # 申請できる残り（承認待ちも引いた残日数）
  def requestable
    requestable_ledger.balance
  end

  # 付与を超えて取得した（どの付与でも賄えない）承認済みの有給の日数
  def shortage
    ledger.shortage
  end

  def shortage?
    shortage.positive?
  end

  def any_grants?
    grants.any?
  end

  # 削除した付与（削除した日時の順）
  def removed_grants
    @removed_grants ||= user.removed_paid_leave_grants.includes(:removed_by).to_a
  end

  # 当年度と使える期間（付与日〜有効期限）が1日でも重なる付与があるか（年5日の印の対象かどうか）。
  # 当年度中に期限が切れた付与・年度の後半に付与した付与も「付与がある」に入る。削除した付与は数えない
  def fiscal_year_grants?
    range = fiscal_year_range
    grants.any? { |grant| grant.usable_during?(range) }
  end

  # 年5日の印を付けるか（当年度に付与があり、当年度の取得が5日に届いていない）
  def annual_target_alert?
    fiscal_year_grants? && below_annual_target?
  end

  # 一番早く失効する残り（[有効期限, 日数]）。無ければ nil
  def next_expiry
    ledger.next_expiry
  end

  def fiscal_year_range
    self.class.fiscal_year_range(today)
  end

  # 当年度の取得日数（承認済み。今日より後の取得予定を含む）
  def fiscal_year_taken_days
    fiscal_year_taken_until_today + fiscal_year_scheduled_days
  end

  # 当年度のうち、今日までに取得した日数
  def fiscal_year_taken_until_today
    range = fiscal_year_range
    days_within(range.begin..[ today, range.end ].min)
  end

  # 当年度のうち、明日以降の取得予定の日数
  def fiscal_year_scheduled_days
    range = fiscal_year_range
    return 0r if today >= range.end

    days_within((today + 1)..range.end)
  end

  # 当年度の取得が5日に届いていないか
  def below_annual_target?
    fiscal_year_taken_days < ANNUAL_TARGET_DAYS
  end

  # 付与・取得・取消・失効・承認待ちの履歴（新しい順）
  def history
    entries = grants.map do |grant|
      HistoryEntry.new(date: grant.granted_on, kind: :grant, days: grant.granted_days, record: grant, usage: nil)
    end
    grants.each do |grant|
      lapsed = ledger.lapsed_days(grant)
      next unless lapsed.positive?

      entries << HistoryEntry.new(date: grant.expires_on + 1, kind: :lapse, days: -lapsed, record: grant, usage: nil)
    end
    effective_leaves.each do |leave|
      entries << HistoryEntry.new(date: leave.target_date, kind: :usage, days: -leave.chargeable_days, record: leave,
                                  usage: ledger.usage_for(leave))
    end
    cancelled_leaves.each do |leave|
      entries << HistoryEntry.new(date: leave.target_date, kind: :cancelled, days: leave.chargeable_days, record: leave, usage: nil)
    end
    pending_leaves.each do |leave|
      entries << HistoryEntry.new(date: leave.target_date, kind: :pending, days: -leave.chargeable_days, record: leave,
                                  usage: requestable_ledger.usage_for(leave))
    end
    removed_grants.each do |grant|
      entries << HistoryEntry.new(date: grant.removed_at.to_date, kind: :removal, days: grant.granted_days, record: grant, usage: nil)
    end
    order = %i[lapse grant usage cancelled pending removal]
    entries.sort_by { |entry| [ entry.date, order.index(entry.kind), entry.record.id.to_i ] }.reverse
  end

  private

  def days_within(range)
    return 0r if range.begin > range.end

    effective_leaves.sum { |leave| leave.chargeable_days_within(range) }
  end
end
