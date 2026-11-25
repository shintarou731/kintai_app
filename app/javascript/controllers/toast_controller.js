import { Controller } from "@hotwired/stimulus"

// 画面上部に重ねて出すメッセージ（トースト）。成功のメッセージは数秒で消える。エラーは閉じるまで残す。
// ページの更新（morph）で同じ要素の中身だけが入れ替わったときも、key が変わるので表示し直す。
const AUTO_HIDE_MS = 5000

export default class extends Controller {
  static values = { key: String, autoHide: Boolean }

  connect() {
    this.show()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  keyValueChanged() {
    this.show()
  }

  show() {
    clearTimeout(this.timer)
    this.element.hidden = false
    if (this.autoHideValue) this.timer = setTimeout(() => this.close(), AUTO_HIDE_MS)
  }

  close() {
    clearTimeout(this.timer)
    this.element.hidden = true
  }
}
