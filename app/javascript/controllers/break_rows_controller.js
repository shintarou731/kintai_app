import { Controller } from "@hotwired/stimulus"

// 打刻修正申請の休憩の行を追加・削除し、「休憩1」「休憩2」…の番号を振り直す
export default class extends Controller {
  static targets = ["list", "template", "row", "label", "addButton"]
  static values = { max: Number }

  connect() {
    this.refresh()
  }

  add() {
    if (this.rowTargets.length >= this.maxValue) return

    const index = `${Date.now()}${Math.floor(Math.random() * 1000)}`
    const html = this.templateTarget.innerHTML.replaceAll("NEW_INDEX", index)
    this.listTarget.insertAdjacentHTML("beforeend", html)
    this.refresh()
    this.rowTargets[this.rowTargets.length - 1].querySelector("input[type=time]")?.focus()
  }

  remove(event) {
    event.currentTarget.closest("[data-break-rows-target=row]").remove()
    this.refresh()
    this.addButtonTarget.focus()
  }

  refresh() {
    this.rowTargets.forEach((row, position) => {
      const number = position + 1
      row.querySelector("[data-break-rows-target=label]").textContent = `休憩${number}`
      row.querySelectorAll("[aria-label]").forEach((element) => {
        element.setAttribute("aria-label", element.getAttribute("aria-label").replace(/休憩\d*/, `休憩${number}`))
      })
    })
    this.addButtonTarget.disabled = this.rowTargets.length >= this.maxValue
  }
}
