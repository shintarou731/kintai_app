# 締めた月度（F14）。管理者が月度を「締め」ると1行でき、その月度の勤怠は変更できなくなる（ClosedPeriodGuard）。
#
# - 締めたときに、その月度の期間と、その時点の勤務ルール（所定労働時間・標準の休憩時間・締め日・警告ライン）を保存し、
#   従業員ごとの集計値と日別の値を MonthlyClosingEntry に保存する。締めた月度の画面・CSV は、保存した値から作る。
#   その後に勤務ルールを変えても、締めた月度の期間も値も変わらない。
# - 締められるのは、期間が終わった（終了日が今日より前の）未締めの月度だけ。期間は AttendanceCalendar の決め方による
#   （となりの月度が締め済みなら、重なり・すき間が出ないように端を合わせた期間で締める）。
# - 解除すると reopened_at・reopened_by が入る（行は消さず、締めと解除の履歴として残す）。解除した月度は、
#   今の勤務ルールで期間も値も計算し直される。もう一度締めると、新しい行で、その時点のルールの値で固定する。
# - 同じ月度で「締めたまま」の行は1つだけ（部分一意インデックス）。2人の管理者が同時に締めても、1件だけになる。
# - 締め・解除は、勤怠を書き換える操作（打刻・申請・承認・直接修正・休暇の直接取消）と同じく書き込みのトランザクションで行う
#   （SQLite は BEGIN IMMEDIATE で書き込みが1つずつになる）。各操作はトランザクションの中で ClosedPeriodGuard を確かめるので、
#   締めと同時に届いても、締めた後の値が変わることはない。
class MonthlyClosing < ApplicationRecord
  class Error < StandardError; end

  belongs_to :closed_by, class_name: "User", optional: true
  belongs_to :reopened_by, class_name: "User", optional: true
  has_many :entries, -> { order(:user_id) }, class_name: "MonthlyClosingEntry", dependent: :destroy, inverse_of: :monthly_closing

  # 締めたまま（解除されていない）
  scope :active, -> { where(reopened_at: nil) }
  # from〜to の期間と1日でも重なる
  scope :overlapping, ->(from, to) { where(start_date: ..to, end_date: from..) }
  scope :recent_first, -> { order(closed_at: :desc, id: :desc) }

  validates :year, :month, :start_date, :end_date, :closed_at, presence: true

  # year 年 month 月の月度を締める。締めた記録（MonthlyClosing）を返す。締められなければ MonthlyClosing::Error
  def self.close!(year:, month:, by:, now: Time.current)
    transaction do
      raise Error, "管理者の権限が無いため、締められません。" unless User.active_admins.exists?(id: by.id)

      # トランザクションの中で、今の勤務ルールと締めの状態を読み直す（同時に届いた締め・設定の変更と食い違わないように）
      rules = WorkRules.current
      period = rules.calendar.period(year, month)
      raise Error, "#{period.label}はすでに締め済みです（#{closing_summary(period.closing)}）。" if period.closed?
      unless period.ended?(today: now.to_date)
        raise Error, "#{period.label}（#{range_label(period)}）はまだ終わっていないため、締められません。#{I18n.l(period.end_date + 1, format: :short_with_day)}以降に締めてください。"
      end

      summary = MonthlySummary.new(period: period, rules: rules, now: now)
      closing = create!(year: year, month: month, start_date: period.start_date, end_date: period.end_date,
                        closing_day: rules.closing_day, scheduled_work_minutes: rules.scheduled_work_minutes,
                        standard_break_minutes: rules.standard_break_minutes, overtime_warning_hours: rules.overtime_warning_hours,
                        closed_by: by, closed_at: now)
      summary.rows.each { |row| closing.entries.create!(MonthlyClosingEntry.attributes_from(row.monthly)) }
      closing
    end
  rescue ActiveRecord::RecordNotUnique
    raise Error, "他の管理者が同時にこの月度を締めました。画面を再読み込みして、締めの状態を確認してください。"
  end

  def self.range_label(period)
    "#{I18n.l(period.start_date, format: :short_with_day)}〜#{I18n.l(period.end_date, format: :short_with_day)}"
  end

  def self.closing_summary(closing)
    by = closing.closed_by ? "#{closing.closed_by.name}・" : ""
    "#{by}#{I18n.l(closing.closed_at, format: :short)}"
  end

  # 締めを解除する。締めたままでなければ MonthlyClosing::Error
  def reopen!(by:, now: Time.current)
    self.class.transaction do
      raise Error, "管理者の権限が無いため、締めを解除できません。" unless User.active_admins.exists?(id: by.id)

      current = self.class.lock.find(id)
      raise Error, "#{label}の締めは、すでに#{current.reopened_by&.name}さんが解除しています。" unless current.active?

      current.update!(reopened_at: now, reopened_by: by)
      reload
    end
  end

  def active?
    reopened_at.nil?
  end

  # 締めた時点の勤務ルール（締めた月度の計算・表示に使う）
  def rules
    WorkRules.new(scheduled_work_minutes: scheduled_work_minutes, standard_break_minutes: standard_break_minutes,
                  closing_day: closing_day, overtime_warning_hours: overtime_warning_hours)
  end

  # 「2026年11月度」（締めた時点で月末締めなら「2026年11月」）
  def label
    closing_day ? "#{year}年#{month}月度" : "#{year}年#{month}月"
  end

  # 「10/21(水)〜11/20(金)」
  def range_label
    "#{I18n.l(start_date, format: :short_with_day)}〜#{I18n.l(end_date, format: :short_with_day)}"
  end

  def to_param_month
    format("%04d-%02d", year, month)
  end
end
