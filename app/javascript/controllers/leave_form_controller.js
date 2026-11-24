import { Controller } from "@hotwired/stimulus"

// 休暇申請の入力：半休を選んだら終了日を開始日に合わせて固定し、
// 開始日より前の終了日を直し、日数（休日＝土日・祝日を除く。半休は0.5日）を表示する。
// 祝日はサーバー側（HolidayCalendar）で判定した一覧を holidays の値（{ "2026-11-23": "勤労感謝の日" }）で受け取る。
// 終了日が開始日と同じ（1日だけの申請）だったときは、開始日を変えると終了日も一緒に動かす
// （過去の日付を選んだときに、終了日の初期値「今日」が残って複数日の申請になるのを防ぐ）。
// 最終的な確かめはサーバー側で行う（JavaScript が無くても申請できる）。
export default class extends Controller {
  static targets = ["start", "end", "dayPart", "days"]
  static values = { holidays: Object }

  connect() {
    this.previousStart = this.startTarget.value
    this.sync()
  }

  sync() {
    const start = this.startTarget.value
    const halfDay = this.halfDay

    if (start) {
      this.endTarget.min = start
      const end = this.endTarget.value
      const followsStart = end === this.previousStart
      if (halfDay || !end || end < start || followsStart) this.endTarget.value = start
      this.previousStart = start
    }
    this.endTarget.readOnly = halfDay
    this.endTarget.setAttribute("aria-readonly", halfDay ? "true" : "false")
    this.renderDays(halfDay)
  }

  get halfDay() {
    const checked = this.dayPartTargets.find((input) => input.checked)
    return checked ? checked.value !== "full_day" : false
  }

  renderDays(halfDay) {
    if (!this.hasDaysTarget) return

    const start = this.parse(this.startTarget.value)
    const end = this.parse(this.endTarget.value)
    if (!start || !end || end < start) {
      this.daysTarget.textContent = ""
      return
    }

    let workingDays = 0
    let total = 0
    const holidays = []
    for (let day = new Date(start); day <= end && total <= 366; day.setUTCDate(day.getUTCDate() + 1)) {
      total += 1
      const weekday = day.getUTCDay()
      const holiday = this.holidaysValue[day.toISOString().slice(0, 10)]
      if (holiday) holidays.push(`${day.getUTCMonth() + 1}/${day.getUTCDate()} ${holiday}`)
      if (weekday !== 0 && weekday !== 6 && !holiday) workingDays += 1
    }
    const days = halfDay ? workingDays / 2 : workingDays
    const dayOffNote = workingDays < total ? "（土日・祝日を除く）" : ""
    const holidayNote = holidays.length > 0 ? `・祝日：${holidays.join("、")}` : ""
    this.daysTarget.textContent = `日数：${days}日${dayOffNote}・期間 ${total}日間${holidayNote}`
  }

  parse(value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null
    const [year, month, day] = value.split("-").map(Number)
    return new Date(Date.UTC(year, month - 1, day))
  }
}
