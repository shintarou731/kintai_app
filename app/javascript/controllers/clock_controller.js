import { Controller } from "@hotwired/stimulus"

const TIME_ZONE = "Asia/Tokyo"
const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"]

// ホーム画面の時計。現在の日付と時刻（日本時間・秒まで）を1秒ごとに更新する。
// 打刻はサーバーの時刻で記録されるため、端末の時計がずれていてもサーバーの時刻に合わせて表示する。
// 勤務中の実働時間・休憩中の休憩時間（duration ターゲット）も分単位で進める。
// このコントローラはホーム画面のページ全体に付ける（打刻カードの外にある「今日の勤務」も対象にするため）。
// 開発用（DEV_NOW）の注意書きの時刻にも使う（その場合は reload-on-date-change を false にする）。
export default class extends Controller {
  static targets = ["date", "time", "duration"]
  static values = {
    serverNow: Number, // 表示したときのサーバーの現在時刻（ミリ秒）
    reloadOnDateChange: { type: Boolean, default: true } // 日付が変わったら画面を読み込み直すか
  }

  connect() {
    this.offset = this.hasServerNowValue ? this.serverNowValue - Date.now() : 0
    this.partsFormat = new Intl.DateTimeFormat("ja-JP", {
      timeZone: TIME_ZONE,
      year: "numeric", month: "numeric", day: "numeric",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
      hourCycle: "h23"
    })
    this.initialDate = null
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  tick() {
    const now = new Date(Date.now() + this.offset)
    const parts = Object.fromEntries(this.partsFormat.formatToParts(now).map((part) => [part.type, part.value]))
    const dateText = `${parts.year}年${Number(parts.month)}月${Number(parts.day)}日(${this.weekdayOf(now)})`

    if (this.hasDateTarget) this.dateTarget.textContent = dateText
    if (this.hasTimeTarget) this.timeTarget.textContent = `${parts.hour}:${parts.minute}:${parts.second}`
    this.durationTargets.forEach((element) => this.updateDuration(element, now))

    // 開いたまま日付が変わったら（日本時間の0時）、「今日」の表示を更新するため画面を読み込み直す
    if (this.initialDate === null) {
      this.initialDate = dateText
    } else if (this.initialDate !== dateText && this.reloadOnDateChangeValue) {
      clearInterval(this.timer)
      window.Turbo ? window.Turbo.visit(window.location.href, { action: "replace" }) : window.location.reload()
    }
  }

  weekdayOf(date) {
    // 日本時間での曜日（UTC に 9 時間足して求める）
    return WEEKDAYS[new Date(date.getTime() + 9 * 60 * 60 * 1000).getUTCDay()]
  }

  // 表示する分数 ＝ data-base-minutes ＋（data-started-at から今までの分数）。
  // サーバー側（Attendance）と同じく、秒を切り捨てた時刻どうしの差で数える。
  updateDuration(element, now) {
    const startedAt = Number(element.dataset.startedAt)
    if (!startedAt) return

    const baseMinutes = Number(element.dataset.baseMinutes) || 0
    const runningMinutes = Math.floor(now.getTime() / 60000) - Math.floor(startedAt / 60000)
    const minutes = Math.max(0, baseMinutes + runningMinutes)
    element.textContent = `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}`
  }
}
