# シフトの週ごとの公開の記録（F11）。管理者が週を「公開」するたびに1件増える（公開の履歴）。
# 追加・変更・削除の件数は、その公開で従業員に反映した数。
class ShiftPublication < ApplicationRecord
  belongs_to :published_by, class_name: "User", optional: true

  scope :for_week, ->(week_start) { where(week_start: week_start) }
  scope :latest_first, -> { order(published_at: :desc, id: :desc) }

  def total_count
    added_count + changed_count + removed_count
  end

  # 「追加 3件・変更 1件・削除 1件」（0件の種類は出さない）
  def summary
    self.class.summary_of(added: added_count, changed: changed_count, removed: removed_count)
  end

  def self.summary_of(added:, changed:, removed:)
    parts = { "追加" => added, "変更" => changed, "削除" => removed }.filter_map { |label, count| "#{label} #{count}件" if count.positive? }
    parts.empty? ? "変更なし" : parts.join("・")
  end
end
