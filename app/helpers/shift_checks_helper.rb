# 予実比較（F12。ShiftCheck）の表示：遅刻・早退・欠勤の印と、予定（公開中のシフト）の時間帯
module ShiftChecksHelper
  SHIFT_MARKS = {
    late: { label: "遅刻", modifier: "danger-soft", title: "シフトの開始時刻より後に出勤しました（1分までは遅刻にしません）" },
    early_leave: { label: "早退", modifier: "danger-soft", title: "シフトの終了時刻より前に退勤しました（1分までは早退にしません）" },
    absent: { label: "欠勤", modifier: "danger", title: "シフトがあるのに、出勤の打刻も休暇もありません" }
  }.freeze

  # 遅刻・早退・欠勤の印（バッジ）。遅刻・早退は分も添える（「遅刻 5分」）
  def shift_mark_badges(check)
    safe_join(check.marks.map do |mark|
      config = SHIFT_MARKS.fetch(mark)
      minutes = { late: check.late_minutes, early_leave: check.early_leave_minutes }[mark]
      text = minutes ? "#{config[:label]} #{format_duration(minutes)}" : config[:label]
      tag.span(text, class: [ "badge", "badge--#{config[:modifier]}", "shift-mark" ], title: config[:title],
                     data: { testid: "shift-mark", mark: mark })
    end, " ")
  end

  # 公開中のシフトの時間帯（「9:00〜18:00」「22:00〜翌6:00」）
  def published_shift_range(shift)
    shift.published_range_label
  end

  # 公開中のシフトの時間帯と休憩（「9:00〜18:00・休憩60分」）
  def published_shift_detail(shift)
    "#{shift.published_range_label}・#{shift_break_label(shift.published_break_minutes)}"
  end

  # 公開後に変わったシフトの印
  def shift_revised_badge(shift)
    return if shift&.revised_at.nil?

    tag.span("変更あり", class: "badge badge--warning shift-revised", title: "#{l(shift.revised_at, format: :short)} に変更が公開されました",
                         data: { testid: "shift-revised" })
  end

  # 半休のため、判定の基準の時刻を動かしたときの説明（「午前半休のため 13:00 を出勤の基準にします」）
  def shift_check_basis_note(check)
    return unless check.adjusted_for_half_day?

    parts = []
    parts << "出勤 #{format_clock_time(check.expected_starts_at)}" if check.expected_starts_at != check.scheduled_starts_at
    parts << "退勤 #{format_clock_time(check.expected_ends_at)}" if check.expected_ends_at != check.scheduled_ends_at
    labels = check.half_day_leaves.map(&:day_part_label).join("・")
    tag.span("#{labels}のため #{parts.join('・')} を基準に判定", class: "shift-check__basis", data: { testid: "shift-check-basis" })
  end

  STATUS_NOTES = {
    no_shift: "シフトなし",
    on_leave: "休暇",
    upcoming: "これから",
    working: "勤務中（早退は退勤後に判定）",
    missing_clock_out: "退勤漏れ（早退は判定できません）",
    left_before_start: "シフトの開始前に退勤（早退はシフトの終了後に判定）",
    done: "予定どおり"
  }.freeze

  # 判定の欄：印があれば印、無ければ状態の説明。半休で基準を動かした日は、その説明も添える
  def shift_check_summary(check)
    parts = []
    if check.marked?
      parts << shift_mark_badges(check)
      parts << tag.span(STATUS_NOTES[:missing_clock_out], class: "muted shift-check__note") if check.status == :missing_clock_out
    elsif (pending = shift_check_pending_badge(check))
      parts << pending
    else
      parts << tag.span(STATUS_NOTES.fetch(check.status), class: [ "shift-check__note", ("muted" unless check.status == :done) ],
                                                          data: { testid: "shift-check-status", status: check.status })
    end
    parts << shift_check_basis_note(check)
    safe_join(parts.compact, " ")
  end

  # まだ決まっていない今日の状態（「未出勤」）。決まっていれば nil
  def shift_check_pending_badge(check)
    case check.status
    when :not_clocked_in
      tag.span("未出勤", class: "badge badge--warning", title: "シフトの開始時刻を過ぎましたが、まだ出勤の打刻がありません",
                         data: { testid: "shift-pending", status: "not_clocked_in" })
    end
  end
end
