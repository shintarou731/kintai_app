# シフトの週単位の公開（F11）。
#
#   publication = ShiftWeekPublication.new(week_start: monday, admin: current_user)
#   publication.save # => true / false（errors に理由）
#
# - その週（月〜日）の、公開されていない変更（未公開のシフト・公開後の変更・削除予定）をまとめて従業員に反映する。
#   - 未公開・変更：下書きの内容を published_* に写す（変更は revised_at も入れる）。
#   - 削除予定：行ごと消す。
# - 無効な従業員のシフトも、その週のものは一緒に公開する（表には出さないが、データは週の公開の対象）。
# - トランザクションの中でその週の行をロックしてから読み直すので、2人の管理者が同時に公開しても、反映されるのは1回だけ
#   （後の側は「公開する変更がありません」になる）。公開と同時に保存された編集は、公開の前か後のどちらかに確実に入る
#   （後なら「公開後の変更」として残る）。SQLite は BEGIN IMMEDIATE で書き込みを1つずつ行う。
# - 通知（F16）：公開が確定した後に、この公開で見えるシフトが変わった従業員だけに通知する（公開済みの週を再公開したときは、
#   変更・追加・削除があった本人だけ）。下書きのまま削除したシフト（従業員に見えていなかった）は通知に含めない。
class ShiftWeekPublication
  include ActiveModel::Model

  attr_reader :week_start, :admin, :record

  def initialize(week_start:, admin:)
    @week_start = week_start
    @admin = admin
    super()
  end

  def week_range
    week_start..(week_start + 6)
  end

  def save(now: Time.current)
    published = false
    ShiftPublication.transaction do
      shifts = Shift.on_dates(week_range).lock.to_a.select(&:pending_publication?)
      if shifts.empty?
        errors.add(:base, "この週には公開する変更がありません（すでに公開済みです。他の管理者が先に公開した可能性もあります）。")
        raise ActiveRecord::Rollback
      end

      counts = { added: 0, changed: 0, removed: 0 }
      @changes_by_user = Hash.new { |hash, user_id| hash[user_id] = { added: [], changed: [], removed: [] } }
      shifts.each do |shift|
        case shift.state
        when :removing
          # 従業員に見えていた（公開済みの）シフトの削除だけを、本人への通知に含める
          @changes_by_user[shift.user_id][:removed] << shift.work_date if shift.published_once?
          shift.delete
          counts[:removed] += 1
        when :changed
          shift.publish_draft!(now: now)
          @changes_by_user[shift.user_id][:changed] << shift.work_date
          counts[:changed] += 1
        else
          shift.publish_draft!(now: now)
          @changes_by_user[shift.user_id][:added] << shift.work_date
          counts[:added] += 1
        end
      end

      @record = ShiftPublication.create!(week_start: week_start, published_by: admin, published_at: now,
                                         added_count: counts[:added], changed_count: counts[:changed], removed_count: counts[:removed])
      published = true
    end
    # 公開が確定した後に、見えるシフトが変わった本人だけに通知する（通知が作れなくても公開は取り消さない。F16）
    notify_changes if published
    published
  rescue DatabaseLockError
    errors.add(:base, DatabaseLockError::MESSAGE)
    false
  end

  # この公開で、従業員ごとに見えるシフトが変わった日（{ user_id => { added: [日付], changed: [...], removed: [...] } }）
  def changes_by_user
    (@changes_by_user || {}).reject { |_user_id, dates| dates.values.all?(&:empty?) }.transform_values(&:dup)
  end

  private

  def notify_changes
    changes = changes_by_user
    Notifier.shifts_published(week_start: week_start, admin: admin, changes: changes) if changes.any?
  end
end
