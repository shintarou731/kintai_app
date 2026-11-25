# シフトパターン（F11）：よく使う時間帯（例：「早番 9:00〜18:00・休憩60分」）。シフト表のマスに素早く割り当てるために使う。
#
# - 割り当てると、パターンの時刻と休憩がシフトに写される（シフトはパターンを参照しない）。
#   そのため、パターンを変更・削除しても、すでに作ったシフトは変わらない。
# - シフト表では、時刻と休憩がパターンと同じシフトに、パターンの名前（「早番」）を添えて表示する。
class ShiftPattern < ApplicationRecord
  include ShiftTimeFields

  NAME_MAX_LENGTH = 20
  MAX_COUNT = 20

  normalizes :name, with: ->(name) { name.unicode_normalize(:nfkc).strip }

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }, uniqueness: true
  validate :count_must_be_within_limit, on: :create

  scope :ordered, -> { order(:start_minute, :end_minute, :name, :id) }

  # 時刻と休憩が同じ組み合わせ → パターン（同じ組み合わせが複数あれば、並び順で先のもの）
  def self.index_by_times(patterns = ordered.to_a)
    patterns.each_with_object({}) { |pattern, result| result[pattern.times_key] ||= pattern }
  end

  private

  def count_must_be_within_limit
    errors.add(:base, :too_many, count: MAX_COUNT) if self.class.count >= MAX_COUNT
  end
end
