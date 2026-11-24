module ApplicationHelper
  # ナビゲーションのリンク。現在の画面（またはその配下）なら aria-current を付ける
  def nav_link_to(label, path, active: current_page?(path), **options)
    classes = [ options.delete(:class), ("is-active" if active) ].compact.join(" ")
    link_to label, path, class: classes, "aria-current": (active ? "page" : nil), **options
  end

  # 有効/無効の状態バッジ
  def user_status_badge(user)
    tag.span(user.status_label, class: [ "badge", user.active? ? "badge--success" : "badge--muted" ])
  end

  # 時刻を「09:02」の形で表示する（JST）。nil なら placeholder
  def format_clock_time(time, placeholder: "--:--")
    time ? l(time.in_time_zone, format: :time) : placeholder
  end

  # 時間（分）を「7:45」（時:分）の形で表示する
  def format_duration(minutes)
    minutes = minutes.to_i
    format("%d:%02d", minutes / 60, minutes % 60)
  end

  # 進行中の時間（勤務中の実働時間・休憩中の休憩時間）。ホーム画面の時計（clock コントローラ）が
  # 「base_minutes ＋ since から今までの分数」で数え直して表示を進める（数え方は Attendance と同じ分単位）
  def running_duration_tag(minutes, since:, base_minutes:)
    tag.span(format_duration(minutes),
             data: { clock_target: "duration", started_at: (since.to_f * 1000).to_i, base_minutes: base_minutes })
  end

  TIME_CLOCK_STATES = {
    not_started: { label: "未出勤", modifier: "neutral" },
    working: { label: "勤務中", modifier: "working" },
    on_break: { label: "休憩中", modifier: "break" },
    finished: { label: "退勤済み", modifier: "neutral" }
  }.freeze

  # 打刻の状態表示（勤務中＝緑、休憩中＝黄、未出勤・退勤済み＝グレー）
  def time_clock_status(state)
    config = TIME_CLOCK_STATES.fetch(state)
    tag.span(config[:label], class: [ "status", "status--#{config[:modifier]}" ], data: { testid: "time-clock-status" })
  end

  def user_role_badge(user)
    tag.span(user.role_label, class: [ "badge", user.admin? ? "badge--accent" : "badge--outline" ])
  end
end
