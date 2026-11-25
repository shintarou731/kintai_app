import { Controller } from "@hotwired/stimulus"

// シフトの入力：パターンのボタンで開始・終了・休憩を入れる。入力に合わせて、勤務時間と実働の予定、日付をまたぐかを表示する。
// 半休の日は、入力した時間が半休の時間（午前半休は〜12:00・午後半休は13:00〜。サーバーの HalfDayLeaveWindow と同じ）と
// 重なるかも知らせる（halfDays：[{ label, from, to }]。その日の 0:00 からの分）。
// 最終的な確かめ（終了＝開始、休憩が勤務時間以上など）はサーバー側で行う。
export default class extends Controller {
  static targets = ["start", "end", "break", "preview"]
  static values = { halfDays: Array }

  connect() {
    this.preview()
  }

  fill(event) {
    const button = event.currentTarget
    this.startTarget.value = button.dataset.start
    this.endTarget.value = button.dataset.end
    this.breakTarget.value = button.dataset.break
    this.preview()
  }

  preview() {
    const start = this.parse(this.startTarget.value)
    const end = this.parse(this.endTarget.value)
    const preview = this.previewTarget
    preview.classList.remove("shift-form__preview--warning")
    if (start === null || end === null) {
      preview.textContent = ""
      return
    }
    if (start === end) {
      preview.textContent = "終了時刻が開始時刻と同じです（勤務時間が0になるため登録できません）"
      preview.classList.add("shift-form__preview--warning")
      return
    }

    const span = (end - start + 1440) % 1440
    const breakText = this.breakTarget.value.trim()
    const breakMinutes = /^\d+$/.test(breakText) ? Number(breakText) : (breakText === "" ? 0 : null)
    const overnight = end < start
    const range = `${this.format(start)}〜${overnight ? "翌" : ""}${this.format(end)}`
    if (breakMinutes === null) {
      preview.textContent = `${range}（勤務時間 ${this.format(span)}）。休憩時間は分の数値で入力してください`
      preview.classList.add("shift-form__preview--warning")
    } else if (breakMinutes >= span) {
      preview.textContent = `${range}：休憩時間（${breakMinutes}分）が勤務時間（${this.format(span)}）以上です`
      preview.classList.add("shift-form__preview--warning")
    } else {
      const note = overnight ? "・日付をまたいで翌日に終わります" : ""
      const overlaps = this.halfDaysValue.filter((window) => start < window.to && window.from < start + span)
      const halfDayNote = overlaps.length > 0 ? `。${overlaps.map((window) => window.label).join("・")}の時間と重なっています` : ""
      preview.textContent = `${range}・勤務時間 ${this.format(span)}・実働の予定 ${this.format(span - breakMinutes)}${note}${halfDayNote}`
      if (overlaps.length > 0) preview.classList.add("shift-form__preview--warning")
    }
  }

  parse(value) {
    const match = /^(\d{1,2}):(\d{2})/.exec(value || "")
    if (!match) return null
    const hour = Number(match[1])
    const minute = Number(match[2])
    return hour < 24 && minute < 60 ? hour * 60 + minute : null
  }

  format(minutes) {
    return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}`
  }
}
