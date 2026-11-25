# シフトパターンをシフト表のマスに割り当てる（F11。シフト表で「パターンで割り当て」を選んでマスを押したとき）。
#
#   assignment = ShiftAssignment.new(user:, date:, pattern:, admin:, expected_lock_version:)
#   assignment.save # => true / false（errors に理由）
#
# - 空いているマス（削除予定のマスを含む）にはシフトを登録し、シフトがあるマスはパターンの時刻と休憩に置き換える（下書き）。
# - expected_lock_version は、管理者が画面で見ていたマスの状態（空なら nil、シフトがあればその lock_version）。
#   その後に他の管理者がマスを変えていたら、割り当てずに知らせる（見ていない内容を上書きしない）。
# - 承認済みの全日の休暇の日には割り当てない（警告を出す）。休暇の日に入れるには、マスを開いて確認のうえ登録する。
class ShiftAssignment
  include ActiveModel::Model

  CONFLICT_MESSAGE = "他の管理者が同時にこのマスを変更したため、割り当てませんでした。最新の内容を確認してから、もう一度お試しください。".freeze

  attr_reader :user, :date, :pattern, :admin, :expected_lock_version, :shift

  def initialize(user:, date:, pattern:, admin:, expected_lock_version: nil)
    @user = user
    @date = date
    @pattern = pattern
    @admin = admin
    @expected_lock_version = expected_lock_version.presence&.to_i
    super()
  end

  def unchanged?
    @unchanged == true
  end

  def save
    saved = false
    Shift.transaction do
      @shift = Shift.find_or_initialize_by(user_id: user.id, work_date: date)
      raise ActiveRecord::Rollback unless matches_expected_state?

      if @shift.persisted? && @shift.live? && @shift.times_key == pattern.times_key
        @unchanged = true
        saved = true
        raise ActiveRecord::Rollback
      end

      if (leave = Shift.effective_leaves_on(user.id, date).find(&:full_day?))
        errors.add(:base, "#{I18n.l(date, format: :short_with_day)} は #{user.name} さんの休暇（#{leave.day_label}）の日のため、割り当てませんでした。" \
                          "休暇の日にシフトを入れる場合は、マスを開いて確認したうえで登録してください。")
        raise ActiveRecord::Rollback
      end

      @shift.user = user
      @shift.assign_attributes(start_minute: pattern.start_minute, end_minute: pattern.end_minute, break_minutes: pattern.break_minutes,
                               removed_at: nil, updated_by: admin)
      @shift.created_by ||= admin
      unless @shift.save
        @shift.errors.full_messages.each { |message| errors.add(:base, message) }
        raise ActiveRecord::Rollback
      end
      saved = true
    end
    saved
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
    errors.add(:base, CONFLICT_MESSAGE)
    false
  rescue DatabaseLockError
    errors.add(:base, DatabaseLockError::MESSAGE)
    false
  end

  private

  # 画面で見ていたマスの状態と、今のマスの状態が同じか
  def matches_expected_state?
    current = @shift.persisted? && @shift.live? ? @shift.lock_version : nil
    return true if current == expected_lock_version

    errors.add(:base, CONFLICT_MESSAGE)
    false
  end
end
