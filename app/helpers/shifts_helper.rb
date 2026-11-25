module ShiftsHelper
  SHIFT_STATE_BADGES = {
    draft: { label: "下書き", modifier: "shift-draft", title: "まだ公開していません。従業員には見えません" },
    published: { label: "公開中", modifier: "success", title: "公開済みです。従業員に見えています" },
    changed: { label: "変更・未公開", modifier: "warning", title: "公開した後に変更しました。週を公開するまで、従業員には変更前の内容が見えます" },
    removing: { label: "削除・未公開", modifier: "danger-soft", title: "削除しました。週を公開するまで、従業員には公開中の内容が見えます" }
  }.freeze

  WEEK_STATUS_BADGES = {
    empty: { label: "シフトなし", modifier: "muted" },
    draft: { label: "下書き（未公開）", modifier: "shift-draft" },
    changed: { label: "公開後の変更あり（未公開）", modifier: "warning" },
    published: { label: "公開済み", modifier: "success" }
  }.freeze

  def shift_state_badge(state)
    config = SHIFT_STATE_BADGES.fetch(state)
    tag.span(config[:label], class: [ "badge", "badge--#{config[:modifier]}", "shift-cell__state" ], title: config[:title],
                             data: { testid: "shift-state", state: state })
  end

  def shift_week_status_badge(status)
    config = WEEK_STATUS_BADGES.fetch(status)
    tag.span(config[:label], class: [ "badge", "badge--#{config[:modifier]}" ], data: { testid: "week-status", status: status })
  end

  # 時刻の入力欄（type=time）の値。「9:00」→「09:00」。解釈できない入力はそのまま返す
  def shift_time_input_value(value)
    minute = Shift.parse_clock_time(value)
    minute ? format("%02d:%02d", minute / 60, minute % 60) : value
  end

  # 「休憩60分」（0分なら「休憩なし」）
  def shift_break_label(minutes)
    minutes.to_i.positive? ? "休憩#{minutes}分" : "休憩なし"
  end

  # 「実働 8:00」
  def shift_work_label(record)
    minutes = record.scheduled_work_minutes
    minutes ? "実働 #{format_duration(minutes)}" : ""
  end

  # 列見出しのクラス（土曜＝青、日曜・祝日＝赤、今日）
  def shift_day_class(board, date)
    kind = board.day_kind(date)
    [ ("shift-day--#{kind}" unless kind == :weekday), ("shift-day--today" if date == board.today) ].compact.join(" ")
  end

  # 前週のコピーの確認の文言（件数の見込み）
  def shift_copy_confirm(board)
    plan = board.copy_plan
    source_from = l(board.week_start - 7, format: :short)
    source_to = l(board.week_start - 1, format: :short)
    lines = [ "前週（#{source_from}〜#{source_to}）のシフトを、この週にコピーします（下書き）。", "コピーする見込み：#{plan.copied}件" ]
    skipped = ShiftWeekCopy.skipped_summary(plan)
    lines << "コピーしない：#{skipped}（すでにあるシフトは上書きしません）" if skipped
    lines << "無効な従業員のシフト #{plan.inactive}件 はコピーしません" if plan.inactive.positive?
    if (half_day = ShiftWeekCopy.half_day_summary(plan))
      lines << "注意：#{half_day} があります（コピーはします。コピーした後に時間を確かめてください）"
    end
    lines << "よろしいですか？"
    lines.join("\n")
  end

  def shift_publish_confirm(board)
    counts = board.pending_counts
    "#{l(board.week_start, format: :short)}〜#{l(board.week_end, format: :short)} のシフトを公開します" \
      "（#{ShiftPublication.summary_of(**counts)}）。公開すると従業員の画面に反映されます。よろしいですか？"
  end
end
