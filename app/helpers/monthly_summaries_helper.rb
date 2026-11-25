module MonthlySummariesHelper
  # 月度の期間の横に出す説明（「（20日締め）」「（20日締めで締め済み）」「（月末締め・締め済みの月度に合わせて調整）」）
  def period_basis_note(period)
    label = WorkRuleSetting.closing_day_label(period.closing_day)
    text = if period.closed? then "#{label}締めで締め済み"
    elsif period.adjusted? then "#{label}締め・締め済みの月度に合わせて期間を調整"
    else "#{label}締め"
    end
    tag.span("（#{text}）", data: { testid: "closing-day" },
                          title: (period.adjusted? ? "締め日どおりなら #{l(period.nominal_start_date, format: :short_with_day)}〜#{l(period.nominal_end_date, format: :short_with_day)}" : nil))
  end

  # 締めの状態のバッジ（「締め済み」「未締め」）
  def period_closing_badge(period)
    if period.closed?
      tag.span("締め済み", class: "badge badge--closed", data: { testid: "closing-status", status: "closed" })
    else
      tag.span("未締め", class: "badge badge--outline", data: { testid: "closing-status", status: "open" })
    end
  end

  # 締めた記録の説明（「山田 太郎 が 11/25 10:00 に締めました」）
  def monthly_closing_by_label(closing)
    "#{closing.closed_by&.name || '（削除されたユーザー）'} が #{l(closing.closed_at, format: :short)} に締めました"
  end

  # 0.5日単位の日数（「1.5日」）。0日は薄く出す
  def monthly_days_cell(days)
    tag.span(LeaveRequest.format_days(days), class: ("muted" if days.zero?))
  end

  # 時間の欄（0:00 は薄く）
  def monthly_minutes_cell(minutes)
    tag.span(format_duration(minutes), class: ("muted" if minutes.zero?))
  end

  # 回数の欄（1回以上は赤）
  def monthly_count_cell(count)
    tag.span("#{count}回", class: count.positive? ? "shift-report__count shift-report__count--alert" : "muted")
  end

  # 日別の勤怠（管理者）の「直接修正」欄：締め済みなら「締め済み」、未来の日は空、それ以外は「修正」（勤怠が無い日は「作成」）
  def admin_attendance_record_cell(day, monthly, edited_dates)
    parts = []
    if monthly.closed?
      parts << tag.span("締め済み", class: "muted history-table__closed", title: "締め済みの月度は直せません（締めを解除すると直せます）")
    elsif day.date <= monthly.today
      label = day.worked? ? "修正" : "作成"
      parts << link_to(label, admin_edit_attendance_record_path(monthly.user.id, day.date.iso8601),
                       class: "history-table__request-link",
                       "aria-label": "#{l(day.date, format: :short_with_day)} の勤怠を#{label}する",
                       data: { testid: "admin-edit-link" })
    end
    if (count = edited_dates[day.date])
      parts << tag.span("修正履歴 #{count}", class: "badge badge--muted", data: { testid: "edited-badge" },
                                            title: "管理者が直接修正した履歴があります（下の「直接修正の履歴」）")
    end
    safe_join(parts, " ")
  end

  # 直接修正の履歴の「修正前」「修正後」の表示（出勤・退勤・休憩・実働）
  def attendance_edit_record_label(attendance, work_date)
    return tag.span("記録なし", class: "muted") if attendance.nil?

    worked = attendance.clocked_out? ? "実働 #{format_duration(attendance.worked_minutes)}" : "退勤なし"
    safe_join([
      tag.span("出勤 #{correction_time_label(attendance.clock_in_at, work_date)}", class: "nowrap"),
      tag.span("退勤 #{correction_time_label(attendance.clock_out_at, work_date)}", class: "nowrap"),
      tag.span("休憩 #{correction_breaks_label(attendance.breaks.to_a, work_date)}"),
      tag.span(worked, class: "nowrap muted")
    ], tag.br)
  end
end
