module AttendancesHelper
  DAY_STATUS_BADGES = {
    working: { label: "勤務中", modifier: "success" },
    on_break: { label: "休憩中", modifier: "warning" },
    missing_clock_out: { label: "退勤漏れ", modifier: "danger" }
  }.freeze

  # 勤怠履歴の1日分の行に付けるクラス（土曜・日曜・祝日・今日・退勤漏れ・勤務なし・休暇）。
  # 日曜と祝日は赤（history-row--sunday / history-row--holiday）、祝日ではない土曜は青（history-row--saturday）。
  # 土曜・日曜の祝日は祝日として扱う（history-row--holiday だけを付ける）
  def attendance_day_row_class(day, today:, leaves: [])
    kind = day.day_kind
    [
      "history-row",
      ("history-row--day-off" unless kind == :weekday),
      ("history-row--#{kind}" unless kind == :weekday),
      ("history-row--today" if day.date == today),
      ("history-row--missing" if day.missing_clock_out?),
      ("history-row--empty" unless day.worked?),
      # 休暇の期間内でも、休日（土日・祝日）は休暇の日数に数えないので、休暇の日の色にしない
      ("history-row--leave" if kind == :weekday && leaves.any?(&:effective?)),
      ("history-row--has-leave" if leaves.any?),
      ("history-row--has-shift" if day.scheduled?),
      ("history-row--marked" if day.shift_check.marked?)
    ].compact.join(" ")
  end

  # 「予定」欄：公開済みのシフトの時間帯（「9:00〜18:00」）。公開後に変わったシフトには「変更あり」。シフトが無い日は空欄
  def attendance_shift_cell(day)
    shift = day.shift
    return "" unless shift

    safe_join([ tag.span(shift.published_range_label, class: "history-table__shift-time", data: { testid: "day-shift" }),
                shift_revised_badge(shift) ].compact, " ")
  end

  # その日の休暇の表示（例：「有給（全日）」「有給（午前半休）」）。承認待ちは「申請中」、取消申請中はその旨を添える。
  # 休暇の期間内の休日（土日・祝日）は日数に数えないので、休暇のバッジではなく「休日（有給の期間中）」と薄く出す
  # （月の休暇の日数・休暇の詳細の日数と、見た目をそろえる）。
  # クリックすると休暇の詳細（申請の詳細）を開く
  def attendance_leave_badges(leaves, date)
    date_label = l(date, format: :short_with_day)
    day_off = HolidayCalendar.day_off?(date)
    safe_join(leaves.map do |leave|
      if day_off
        text = leave.label_on(date)
        link_to text, approval_request_path(leave), class: "badge badge--leave-day-off history-table__leave",
                                                    title: "#{leave.description}の期間中の休日です。休日（土日・祝日）は休暇の日数に数えません",
                                                    "aria-label": "#{date_label} は#{text}。休暇の日数には数えません（休暇の詳細を見る）",
                                                    data: { testid: "day-leave", leave_status: "day-off" }
      elsif leave.effective?
        cancelling = leave.pending_cancellation
        text = leave.label_on(date)
        link_to text, approval_request_path(leave), class: "badge badge--leave history-table__leave",
                                                    title: "#{leave.description}（承認済み）",
                                                    "aria-label": "#{date_label} は#{text}（休暇の詳細を見る）",
                                                    data: { testid: "day-leave", leave_status: cancelling ? "cancelling" : "approved" }
      else
        link_to leave.label_on(date), approval_request_path(leave),
                class: "badge badge--leave-pending history-table__leave",
                title: "#{leave.description}（承認待ち。承認されるまで休暇は確定しません）",
                "aria-label": "#{date_label} は#{leave.day_label}を申請中（休暇の詳細を見る）",
                data: { testid: "day-leave", leave_status: "pending" }
      end
    end, " ")
  end

  # 祝日名のラベル（例：「勤労感謝の日」）。祝日でなければ nil。カード表示（375px）でも日付の横に出る
  def attendance_holiday_label(day)
    name = day.holiday_name
    return unless name

    tag.span(name, class: "history-table__holiday", title: "国民の祝日（休日）", data: { testid: "holiday-name" })
  end

  # 「修正」欄：承認待ちの修正申請がある日は「申請中」（申請の詳細へ）、今日までの日は「修正申請」（入力画面へ）
  def attendance_day_request_cell(day, monthly)
    date_label = l(day.date, format: :short_with_day)
    if (pending = monthly.pending_correction_for(day.date))
      link_to "申請中", approval_request_path(pending), class: "badge badge--warning history-table__pending",
                                                     title: "承認待ちの修正申請があります（承認されるまで記録は変わりません）",
                                                     "aria-label": "#{date_label} は修正申請中（申請の詳細を見る）",
                                                     data: { testid: "pending-correction" }
    elsif monthly.closed?
      tag.span("締め済み", class: "muted history-table__closed", title: "締め済みの月度のため、修正申請できません（直す必要がある場合は管理者に連絡してください）",
                         data: { testid: "closed-day" })
    elsif monthly.correctable?(day.date)
      link_to "修正申請", new_attendance_correction_request_path(date: day.date.iso8601),
              class: "history-table__request-link", "aria-label": "#{date_label} の打刻修正を申請する",
              data: { testid: "correction-link" }
    end
  end

  # 退勤漏れのお知らせに出す、その日の修正申請へのリンク（申請中ならその申請へ）
  def attendance_missing_clock_out_request_link(day, monthly)
    date_label = l(day.date, format: :short_with_day)
    if (pending = monthly.pending_correction_for(day.date))
      link_to "#{date_label} は申請中", approval_request_path(pending), class: "notice-box__link"
    else
      link_to "#{date_label} の修正申請", new_attendance_correction_request_path(date: day.date.iso8601),
              class: "notice-box__link", data: { testid: "missing-clock-out-request-link" }
    end
  end

  # 勤務の状態バッジ（退勤済みの日は出さない）。退勤漏れでもまだホームから退勤できる日は、その期限も添える
  def attendance_day_status_badge(day)
    config = DAY_STATUS_BADGES[day.status]
    return unless config

    badge = tag.span(config[:label], class: [ "badge", "badge--#{config[:modifier]}" ], data: { testid: "day-status" })
    return badge unless day.clock_out_open?

    safe_join([ badge, tag.span("ホームで退勤可（〜#{attendance_clock_out_deadline(day.attendance)}）",
                                class: "history-table__open-hint", data: { testid: "clock-out-open-hint" }) ])
  end

  # ホーム画面から退勤を打刻できる期限（例：「11/11(水) 10:00」）
  def attendance_clock_out_deadline(attendance)
    deadline = attendance.clock_out_deadline.in_time_zone
    "#{l(deadline.to_date, format: :short_with_day)} #{format_clock_time(deadline)}"
  end

  # 退勤時刻。出勤した日の翌日以降に退勤した場合は「翌」を付ける
  def attendance_clock_out_cell(day)
    attendance = day.attendance
    return "" unless attendance
    return tag.span("未打刻", class: "history-table__missing") if day.missing_clock_out?
    return tag.span("--:--", class: "muted") unless attendance.clocked_out?

    next_day = attendance.clock_out_at.in_time_zone.to_date > day.date
    safe_join([ (tag.span("翌", class: "history-table__next-day", title: "翌日に退勤") if next_day),
                format_clock_time(attendance.clock_out_at) ].compact)
  end

  # 時間（分）の欄。0:00 は薄く表示する。勤務の無い日は空欄、退勤漏れの日は「—」
  def attendance_duration_cell(day, minutes)
    return "" unless day.worked?
    return tag.span("—", class: "muted", title: "退勤の打刻が無いため計算できません") if day.missing_clock_out?

    tag.span(format_duration(minutes), class: ("muted" if minutes.zero?))
  end
end
