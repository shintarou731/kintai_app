module NotificationsHelper
  # ベルのバッジの表示（100件以上は「99+」）
  def notification_badge_label(count)
    count > Notification::BADGE_MAX ? "#{Notification::BADGE_MAX}+" : count.to_s
  end

  # 通知の発生日時（「11/25(水) 18:02」。今年でなければ年も付ける）
  def notification_time_label(time, now: Time.current)
    time = time.in_time_zone
    date = time.year == now.year ? l(time.to_date, format: :short_with_day) : l(time.to_date, format: :long)
    "#{date} #{l(time, format: :time)}"
  end

  # 発生してからの時間（「たった今」「5分前」「3時間前」「2日前」）。7日より前なら nil（日時だけを出す）
  def notification_relative_label(time, now: Time.current)
    seconds = (now - time).to_i
    return "たった今" if seconds < 60
    return "#{seconds / 60}分前" if seconds < 3600
    return "#{seconds / 3600}時間前" if seconds < 86_400

    days = seconds / 86_400
    "#{days}日前" if days < 7
  end

  # ベルのアイコン（SVG）
  def notification_bell_icon
    tag.svg(xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 24 24", width: 22, height: 22, fill: "none", stroke: "currentColor",
            "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false",
            class: "notifications-menu__icon") do
      tag.path(d: "M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9") + tag.path(d: "M13.73 21a2 2 0 0 1-3.46 0")
    end
  end
end
