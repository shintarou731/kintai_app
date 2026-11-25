import { Controller } from "@hotwired/stimulus"

// 横スクロールする領域（シフト表）の位置を、同じ URL のページの更新（パターンの割り当ての後の morph）の後も保つ。
// morph の途中で中身が入れ替わると、ブラウザが scrollLeft を 0 に戻すことがあるため、描画の直前に覚えて直後に戻す。
// 別の週など、URL が変わったときは戻さない。
const positions = new Map()

export default class extends Controller {
  connect() {
    this.save = this.save.bind(this)
    this.restore = this.restore.bind(this)
    document.addEventListener("turbo:before-render", this.save)
    document.addEventListener("turbo:render", this.restore)
    this.restore()
  }

  disconnect() {
    document.removeEventListener("turbo:before-render", this.save)
    document.removeEventListener("turbo:render", this.restore)
  }

  save() {
    positions.set(this.key, this.element.scrollLeft)
  }

  restore() {
    const left = positions.get(this.key)
    if (left === undefined) return
    positions.delete(this.key)
    const element = document.getElementById(this.element.id) || this.element
    element.scrollLeft = left
  }

  get key() {
    return `${location.pathname}${location.search}#${this.element.id}`
  }
}
