import { Controller } from "@hotwired/stimulus"

// 有給休暇の付与の入力：付与日を変えたら、有効期限を付与日の2年後に合わせる。
// 管理者が有効期限を自分で変えた後は、付与日を変えても有効期限は動かさない。
// 2/29 の2年後は 2/28 にする（サーバー側の Rails の日付計算と同じ）。最終的な確かめはサーバー側で行う。
export default class extends Controller {
  static targets = ["grantedOn", "expiresOn"]

  connect() {
    this.expiryEdited = this.expiresOnTarget.value !== "" && this.expiresOnTarget.value !== this.defaultExpiry(this.grantedOnTarget.value)
  }

  syncExpiry() {
    if (this.expiryEdited) return

    const expiry = this.defaultExpiry(this.grantedOnTarget.value)
    if (expiry) this.expiresOnTarget.value = expiry
  }

  markExpiryEdited() {
    this.expiryEdited = this.expiresOnTarget.value !== this.defaultExpiry(this.grantedOnTarget.value)
  }

  defaultExpiry(value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value || "")) return null
    const [year, month, day] = value.split("-").map(Number)
    const lastDay = new Date(Date.UTC(year + 2, month, 0)).getUTCDate()
    const pad = (number) => String(number).padStart(2, "0")
    return `${year + 2}-${pad(month)}-${pad(Math.min(day, lastDay))}`
  }
}
