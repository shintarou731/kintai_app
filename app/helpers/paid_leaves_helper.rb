module PaidLeavesHelper
  HISTORY_KIND_LABELS = {
    grant: "付与",
    usage: "取得",
    cancelled: "取得の取消",
    lapse: "失効",
    pending: "申請中",
    removal: "付与の削除"
  }.freeze

  HISTORY_KIND_MODIFIERS = {
    grant: "accent",
    usage: "outline",
    cancelled: "muted",
    lapse: "danger",
    pending: "warning",
    removal: "danger"
  }.freeze

  GRANT_STATE_BADGES = {
    active: { label: "有効", modifier: "success" },
    expired: { label: "期限切れ", modifier: "muted" },
    future: { label: "付与日前", modifier: "outline" }
  }.freeze

  # 「残り 7.5日」
  def paid_leave_balance_label(days)
    "残り #{format_leave_days(days)}"
  end

  # 増減の表示（「+10日」「−2日」）
  def paid_leave_signed_days(days)
    value = days.to_r
    sign = value.negative? ? "−" : "+"
    "#{sign}#{format_leave_days(value.abs)}"
  end

  # 履歴の種類のバッジ
  def paid_leave_history_kind_badge(entry)
    label = HISTORY_KIND_LABELS.fetch(entry.kind)
    label = "#{label}（#{entry.record.day_part_label}）" if %i[usage pending].include?(entry.kind)
    tag.span(label, class: [ "badge", "badge--#{HISTORY_KIND_MODIFIERS.fetch(entry.kind)}" ], data: { testid: "paid-leave-history-kind" })
  end

  # 履歴の日付（付与・失効は日付、取得は休暇の期間）
  def paid_leave_history_date(entry)
    case entry.kind
    when :usage, :cancelled, :pending then entry.record.target_label
    else l(entry.date, format: :short_with_day)
    end
  end

  # 付与の状態のバッジ（有効・期限切れ）
  def paid_leave_grant_state_badge(ledger, grant)
    config = GRANT_STATE_BADGES.fetch(ledger.grant_state(grant))
    tag.span(config[:label], class: [ "badge", "badge--#{config[:modifier]}" ], data: { testid: "grant-state" })
  end

  # 付与の説明（例：「2026/04/01 付与（2028/04/01 まで）」）
  def paid_leave_grant_label(grant)
    "#{l(grant.granted_on)} 付与分（#{l(grant.expires_on)} まで）"
  end

  # 取得がどの付与から消化されたか（例：「2026/04/01 付与分から 2日」）
  def paid_leave_usage_sources(usage)
    return "" unless usage

    parts = usage.allocations.map do |allocation|
      "#{l(allocation.grant.granted_on)} 付与分から #{format_leave_days(PaidLeaveLedger.days(allocation.half_days))}"
    end
    parts.join("・")
  end
end
