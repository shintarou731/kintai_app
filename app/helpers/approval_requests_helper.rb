module ApprovalRequestsHelper
  # 状態の色（承認待ち＝黄、承認済み＝緑、却下＝赤、取り下げ＝グレー）
  APPROVAL_REQUEST_STATUS_MODIFIERS = {
    "pending" => "warning",
    "approved" => "success",
    "rejected" => "danger",
    "withdrawn" => "muted"
  }.freeze

  # 状態のバッジ。承認済みの休暇が取り消されていれば「取消済み」も並べる
  def approval_request_status_badge(approval_request)
    badge = tag.span(approval_request.status_label,
                     class: [ "badge", "badge--#{APPROVAL_REQUEST_STATUS_MODIFIERS.fetch(approval_request.status)}" ],
                     data: { testid: "request-status" })
    extra = case approval_request
    when LeaveRequest
      if approval_request.cancelled?
        title = approval_request.directly_cancelled? ? "管理者が休暇を直接取り消しました" : "取消申請が承認され、休暇は取り消されました"
        tag.span("取消済み", class: "badge badge--muted", data: { testid: "leave-cancelled" }, title: title)
      end
    when LeaveCancellationRequest
      if approval_request.closed_by_direct_cancellation?
        tag.span("直接取消で処理済み", class: "badge badge--muted", data: { testid: "closed-by-direct-cancellation" },
                                    title: "管理者が休暇を直接取り消したため、この取消申請は処理済みになりました")
      end
    end
    extra ? safe_join([ badge, extra ], " ") : badge
  end

  # 休暇を直接取り消した管理者と日時（例：「山田 太郎（11/25 09:10）」）。直接取消でなければ nil
  def leave_direct_cancellation_label(leave)
    return nil unless leave.is_a?(LeaveRequest) && leave.directly_cancelled?

    "#{leave.cancelled_by&.name || '（削除されたユーザー）'}（#{l(leave.cancelled_at, format: :short)}）"
  end

  # 申請一覧の「内容」欄（例：「出勤 09:00／退勤 翌 02:00／休憩 1回」「有給休暇・全日（3日）」）
  def approval_request_summary(approval_request)
    case approval_request
    when AttendanceCorrectionRequest
      date = approval_request.target_date
      [ "出勤 #{correction_time_label(approval_request.requested_clock_in_at, date)}",
        "退勤 #{correction_time_label(approval_request.requested_clock_out_at, date, placeholder: '（勤務中）')}",
        "休憩 #{approval_request.breaks.size}回" ].join("／")
    when LeaveRequest
      leave_summary(approval_request)
    when LeaveCancellationRequest
      "#{leave_summary(approval_request.leave_request)} の取消"
    end
  end

  # 休暇の内容（例：「有給休暇・全日（3日）」）
  def leave_summary(leave)
    "#{leave.leave_type_label}・#{leave.day_part_label}（#{leave_days_label(leave)}）"
  end

  # 休暇の日数（例：「3日」「0.5日」。期間に休日（土日・祝日）があれば「2日・土日祝を除く」）
  def leave_days_label(leave)
    days = format_leave_days(leave.chargeable_days)
    leave.includes_day_off? ? "#{days}・土日祝を除く" : days
  end

  # 日数に数えなかった休日の一覧（例：「11/21(土)、11/22(日)、11/23(月) 勤労感謝の日」）。休日が無ければ nil
  def leave_days_off_label(leave)
    days_off = leave.days_off_in_period
    return if days_off.empty?

    days_off.map do |date|
      name = HolidayCalendar.holiday_name(date)
      [ l(date, format: :short_with_day), name ].compact.join(" ")
    end.join("、")
  end

  # 休暇の入力画面で日数を表示するための祝日（{ "2026-11-23" => "勤労感謝の日" }）。申請できる範囲（今日の前後1年）の分
  def leave_form_holidays(today)
    span = LeaveRequest::SUBMITTABLE_SPAN
    HolidayCalendar.holidays_between(today - span, today + span).transform_keys(&:iso8601)
  end

  # 日数（Rational など）を「3日」「1.5日」の形にする
  def format_leave_days(days)
    value = days.to_r
    number = value.denominator == 1 ? value.to_i.to_s : format("%.1f", value.to_f)
    "#{number}日"
  end

  # 承認したときに何が起きるかの説明（承認・却下のフォームの下に出す）
  def approval_effect_note(approval_request)
    case approval_request
    when AttendanceCorrectionRequest then "承認すると、勤怠記録が上の「申請内容」に置き換わります。"
    when LeaveRequest then "承認すると、休暇が確定し、本人の勤怠履歴の該当日に「#{approval_request.day_label}」と表示されます。"
    when LeaveCancellationRequest then "承認すると、この休暇は取り消され、勤怠履歴の表示も消えます。"
    else "承認すると、申請内容が反映されます。"
    end
  end

  # 打刻修正の時刻（対象日の翌日なら「翌 02:00」）
  def correction_time_label(time, target_date, placeholder: "未打刻")
    return placeholder if time.nil?

    time = time.in_time_zone
    days = (time.to_date - target_date).to_i
    prefix = if days == 1 then "翌 "
    elsif days > 1 then "#{l(time.to_date, format: :short)} "
    else ""
    end
    "#{prefix}#{format_clock_time(time)}"
  end

  # 休憩の一覧（例：「12:00〜13:00、翌 00:30〜翌 01:00」）
  def correction_breaks_label(breaks, target_date)
    return "なし" if breaks.empty?

    breaks.map do |item|
      ending = item.ended_at ? correction_time_label(item.ended_at, target_date) : "（休憩中）"
      "#{correction_time_label(item.started_at, target_date)}〜#{ending}"
    end.join("、")
  end

  # 比較表の「今の記録」側の見出し。処理済みなら、処理した時点の記録と比べる
  def correction_comparison_base_label(correction)
    case correction.status
    when "approved" then "承認前の記録"
    when "rejected" then "却下時の記録"
    else "今の記録"
    end
  end

  # 比較表の説明
  def correction_comparison_lead(correction)
    case correction.status
    when "approved" then "色の付いた行が、承認で変わった項目です。"
    when "rejected" then "却下したため、勤怠記録は変わっていません（色の付いた行は申請で変えようとした項目です）。"
    when "withdrawn" then "取り下げたため、勤怠記録は変わっていません。"
    else "色の付いた行が、承認されると変わる項目です。"
    end
  end

  # 処理した管理者と日時（例：「山田 太郎（11/24 22:10）」）
  def approval_request_reviewer_label(approval_request)
    return "—" unless approval_request.reviewed_at

    name = approval_request.reviewer&.name || "（削除されたユーザー）"
    "#{name}（#{l(approval_request.reviewed_at, format: :short)}）"
  end

  # 一覧の「対象日」欄。休暇申請・取消申請は期間（例：「11/26(木)〜11/27(金)」）
  def approval_request_target_label(approval_request)
    approval_request.target_label
  end

  # 詳細の見出しに出す対象日（例：「2026年11月20日(金)」「2026年11月26日(木)〜11月27日(金)」）
  def approval_request_long_target_label(approval_request)
    leave = approval_request.is_a?(LeaveCancellationRequest) ? approval_request.leave_request : approval_request
    start = l(approval_request.target_date, format: :long)
    return start unless leave.is_a?(LeaveRequest) && leave.end_date && !leave.single_day?

    finish = leave.end_date.year == leave.target_date.year ? l(leave.end_date, format: :month_day_with_day) : l(leave.end_date, format: :long)
    "#{start}〜#{finish}"
  end

  # 今の記録と申請内容を並べる行（項目, 今の記録, 申請内容, 変わるか）。
  # 処理済みの申請では、「今の記録」の代わりに処理した時点の記録（承認前の記録）を使う
  def correction_comparison_rows(correction)
    date = correction.target_date
    current = correction.comparison_attendance
    requested = correction.requested_attendance

    current_values = if current
      [ correction_time_label(current.clock_in_at, date),
        correction_time_label(current.clock_out_at, date),
        correction_breaks_label(current.breaks.to_a, date),
        current.clocked_out? ? format_duration(current.worked_minutes) : "—" ]
    else
      [ "未打刻", "未打刻", "なし", "—" ]
    end
    requested_values = [
      correction_time_label(requested.clock_in_at, date),
      correction_time_label(requested.clock_out_at, date, placeholder: "空欄（勤務中）"),
      correction_breaks_label(requested.breaks.to_a, date),
      requested.clocked_out? ? format_duration(requested.worked_minutes) : "—"
    ]

    # 退勤は「未打刻」と「空欄（勤務中）」で表示が違っても、どちらも退勤なしなら変更ではない
    clock_out_unchanged = current&.clock_out_at.nil? && requested.clock_out_at.nil?
    labels = %w[出勤 退勤 休憩 実働時間]
    labels.zip(current_values, requested_values).map do |label, before, after|
      changed = label == "退勤" && clock_out_unchanged ? false : before != after
      { label: label, current: before, requested: after, changed: changed }
    end
  end

  # 打刻修正の入力画面の日付の選択肢（「11/10(火)」＝当日、「翌日 11/11(水)」＝翌日）
  def correction_day_options(target_date)
    [ [ l(target_date, format: :short_with_day), "0" ],
      [ "翌日 #{l(target_date.tomorrow, format: :short_with_day)}", "1" ] ]
  end
end
