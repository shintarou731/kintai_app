import { Controller } from "@hotwired/stimulus"

// <details> を使ったドロップダウンを、外側クリックや Esc キーで閉じる
export default class extends Controller {
  connect() {
    this.closeOnOutsideClick = this.closeOnOutsideClick.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)
    document.addEventListener("click", this.closeOnOutsideClick)
    document.addEventListener("keydown", this.closeOnEscape)
  }

  disconnect() {
    document.removeEventListener("click", this.closeOnOutsideClick)
    document.removeEventListener("keydown", this.closeOnEscape)
  }

  closeOnOutsideClick(event) {
    if (!this.element.contains(event.target)) this.element.open = false
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && this.element.open) {
      this.element.open = false
      this.element.querySelector("summary")?.focus()
    }
  }
}
