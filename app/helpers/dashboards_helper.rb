# 管理者のダッシュボード（F13）の表示
module DashboardsHelper
  # 状態の表示名と色（勤務中＝緑、休憩中＝黄、未出勤・退勤済み＝グレー、休暇＝紫、遅れ＝赤）
  DASHBOARD_STATES = {
    working: { label: "勤務中", modifier: "working" },
    on_break: { label: "休憩中", modifier: "break" },
    finished: { label: "退勤済み", modifier: "neutral" },
    not_started: { label: "未出勤", modifier: "neutral" },
    on_leave: { label: "休暇", modifier: "leave" }
  }.freeze

  def dashboard_state_label(state)
    DASHBOARD_STATES.fetch(state)[:label]
  end

  # 状態の表示。遅れは「未出勤（遅れ）」を赤で出す
  def dashboard_state_badge(row)
    if row.late?
      tag.span("未出勤（遅れ）", class: "status status--danger status--small", data: { testid: "dashboard-state", state: "late" })
    else
      config = DASHBOARD_STATES.fetch(row.state)
      tag.span(config[:label], class: [ "status", "status--#{config[:modifier]}", "status--small" ],
                               data: { testid: "dashboard-state", state: row.state })
    end
  end

  # 遅れの説明（「9:00 開始・0:12 経過」「シフトの終了（18:00）を過ぎました」）
  def dashboard_late_note(row, now)
    check = row.late_check
    return unless check

    text = if check.status == :absent
      "シフトの終了（#{check.expected_ends_at.strftime('%-H:%M')}）を過ぎても出勤がありません"
    else
      prefix = check.equal?(row.previous_check) ? "前日からのシフト・" : ""
      "#{prefix}#{check.expected_starts_at.strftime('%-H:%M')} 開始から #{format_duration(Attendance.minutes_between(check.expected_starts_at, now))} 経過"
    end
    tag.span(text, class: "dashboard-table__late-note", data: { testid: "dashboard-late-note" })
  end

  # 出勤時刻。前日に出勤した勤務は日付を添える（「前日 22:00」）
  def dashboard_clock_in(row)
    attendance = row.attendance
    return tag.span("--:--", class: "muted") unless attendance

    parts = []
    parts << tag.span("前日", class: "dashboard-table__day-tag", title: "#{l(attendance.work_date, format: :short_with_day)} に出勤") if row.overnight?
    parts << tag.span(format_clock_time(attendance.clock_in_at), class: "dashboard-table__time")
    safe_join(parts, " ")
  end

  # 退勤時刻（退勤していなければ空）
  def dashboard_clock_out(row)
    attendance = row.attendance
    return tag.span("--:--", class: "muted") unless attendance&.clocked_out?

    tag.span(format_clock_time(attendance.clock_out_at), class: "dashboard-table__time")
  end
end
