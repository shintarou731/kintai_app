# 前週のシフトを、今の週にまとめてコピーする（F11）。
#
#   copy = ShiftWeekCopy.new(week_start: monday, admin: current_user)
#   copy.plan    # => コピーの見込み（確認のダイアログに出す件数）
#   copy.save    # => true / false（result に件数、errors に理由）
#
# - 前週（月〜日）の、有効な従業員のシフト（削除予定を除く下書きの内容）を、7日後の同じ曜日のマスにコピーする。
#   コピーしたシフトは「下書き」（公開するまで従業員には見えない）。
# - 上書きはしない。次のマスはコピーせずに飛ばし、件数を知らせる。
#   - すでにシフトがあるマス（削除予定のマスは空いているものとしてコピーする）
#   - 承認済みの全日の休暇の日（休暇の日に入れるには、マスを開いて確認のうえ登録する）
#   - 前日・翌日のシフトと時間が重なるなど、そのままでは登録できないマス
#   - 無効な従業員のシフト（無効な従業員は表に出さないため）
# - 承認済みの半休の日には、コピーする（上書きではないため）。ただし、シフトの時間が半休の時間（HalfDayLeaveWindow）と
#   重なるマスは half_day_overlap に件数を数え、確認のダイアログと結果のメッセージで「時間を確かめてください」と知らせる。
# - コピーは1つのトランザクションで、その中でコピー先のマスを読み直す。2人の管理者が同時にコピーしても二重にはならない
#   （後の側は、先の側がコピーしたマスを「すでにシフトがある」として飛ばす）。
class ShiftWeekCopy
  include ActiveModel::Model

  Result = Struct.new(:copied, :existing, :on_leave, :invalid, :inactive, :half_day_overlap, keyword_init: true) do
    def skipped
      existing + on_leave + invalid
    end
  end

  attr_reader :week_start, :admin, :result

  def initialize(week_start:, admin:)
    @week_start = week_start
    @admin = admin
    super()
  end

  def source_range
    (week_start - 7)..(week_start - 1)
  end

  def target_range
    week_start..(week_start + 6)
  end

  # 保存せずに数える（確認のダイアログ用）。保存時にもう一度数え直す
  def plan
    plan = build_plan
    Result.new(copied: plan[:entries].size, existing: plan[:existing], on_leave: plan[:on_leave], invalid: 0, inactive: plan[:inactive],
               half_day_overlap: plan[:entries].count { |entry| entry[2] })
  end

  # 飛ばしたマスの内訳（「すでにシフトがあるマス 3件・休暇の日 1件」）。無ければ nil
  def self.skipped_summary(result)
    parts = []
    parts << "すでにシフトがあるマス #{result.existing}件" if result.existing.positive?
    parts << "休暇の日 #{result.on_leave}件" if result.on_leave.positive?
    parts << "時間が重なるなど登録できないマス #{result.invalid}件" if result.invalid.positive?
    parts.join("・").presence
  end

  # 半休の時間と重なるマスの注意（「半休の時間と重なるマス 1件」）。無ければ nil
  def self.half_day_summary(result)
    return unless result.half_day_overlap.to_i.positive?

    "半休の日で、シフトが半休の時間（#{HalfDayLeaveWindow.description}）と重なるマス #{result.half_day_overlap}件"
  end

  def save(now: Time.current)
    saved = false
    Shift.transaction do
      plan = build_plan
      copied = 0
      half_day_overlap = 0
      invalid = plan[:invalid]
      plan[:entries].each do |source, target, overlap|
        target.assign_attributes(start_minute: source.start_minute, end_minute: source.end_minute, break_minutes: source.break_minutes,
                                 removed_at: nil, updated_by: admin)
        target.created_by ||= admin
        if target.save
          copied += 1
          half_day_overlap += 1 if overlap
        else
          invalid += 1
        end
      end

      @result = Result.new(copied: copied, existing: plan[:existing], on_leave: plan[:on_leave], invalid: invalid, inactive: plan[:inactive],
                           half_day_overlap: half_day_overlap)
      if copied.zero?
        errors.add(:base, nothing_to_copy_message)
        raise ActiveRecord::Rollback
      end
      saved = true
    end
    saved
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
    errors.add(:base, "他の管理者が同時にこの週のシフトを変更したため、コピーできませんでした。画面を再読み込みして、もう一度お試しください。")
    false
  rescue DatabaseLockError
    errors.add(:base, DatabaseLockError::MESSAGE)
    false
  end

  private

  def nothing_to_copy_message
    if result.copied.zero? && result.skipped.zero?
      "前週（#{I18n.l(source_range.begin, format: :short)}〜#{I18n.l(source_range.end, format: :short)}）には、コピーできるシフトがありません。"
    else
      "コピーできるマスがありませんでした（#{self.class.skipped_summary(result)}。上書きはしません）。"
    end
  end

  # entries：[コピー元, コピー先（新しい行か、削除予定の行）, 半休の時間と重なるか] の配列
  def build_plan
    sources = Shift.live.on_dates(source_range).includes(:user).order(:work_date, :user_id).to_a
    inactive, active = sources.partition { |shift| !shift.user.active? }
    targets = Shift.on_dates(target_range).where(user_id: active.map(&:user_id)).index_by { |shift| [ shift.user_id, shift.work_date ] }
    leave_days = full_day_leave_days(active.map(&:user_id))
    half_days = half_day_leaves(active.map(&:user_id))

    plan = { entries: [], existing: 0, on_leave: 0, invalid: 0, inactive: inactive.size }
    active.each do |source|
      date = source.work_date + 7
      target = targets[[ source.user_id, date ]]
      if target&.live?
        plan[:existing] += 1
      elsif leave_days.include?([ source.user_id, date ])
        plan[:on_leave] += 1
      else
        plan[:entries] << [ source, target || Shift.new(user: source.user, work_date: date),
                            overlaps_half_day?(source, date, half_days[[ source.user_id, date ]]) ]
      end
    end
    plan
  end

  # 承認済みの半休（{ [従業員, 日付] => [半休, …] }）
  def half_day_leaves(user_ids)
    leaves = LeaveRequest.effective.where(day_part: %w[morning afternoon], user_id: user_ids).overlapping(target_range.begin, target_range.end)
    leaves.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |leave, result|
      leave.dates.each { |date| result[[ leave.user_id, date ]] << leave if target_range.cover?(date) }
    end
  end

  # コピー元の時間帯を date に写したとき、半休の時間と重なるか
  def overlaps_half_day?(source, date, leaves)
    return false if leaves.blank?

    starts_at = Shift.time_on(date, source.start_minute)
    ends_at = Shift.time_on(source.overnight? ? date + 1 : date, source.end_minute)
    leaves.any? { |leave| HalfDayLeaveWindow.overlaps?(leave, date, starts_at, ends_at) }
  end

  # 承認済みの全日の休暇がある [従業員, 日付] の集合
  def full_day_leave_days(user_ids)
    leaves = LeaveRequest.effective.full_day.where(user_id: user_ids).overlapping(target_range.begin, target_range.end)
    leaves.each_with_object(Set.new) do |leave, days|
      leave.dates.each { |date| days << [ leave.user_id, date ] if target_range.cover?(date) }
    end
  end
end
