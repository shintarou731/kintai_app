# 残業の警告（F16）。従業員の月度の残業時間が、警告ライン（F6）の 80% と 100% を超えたときに、それぞれ1回だけ
# 本人と有効な管理者へ通知する。送った記録を、従業員・月度（period_key）・段階（level）ごとに1件だけ残す（一意制約）。
#
#   OvertimeAlert.check(user, date: attendance.work_date)  # 1人分（退勤・修正申請の承認・管理者の直接修正のあと）
#   OvertimeAlert.check_all                                 # 有効なユーザー全員の今月度（勤務ルールの変更のあと）
#
# 決まり
# - 「超えた」は、勤怠履歴・ダッシュボードと同じく、ちょうどは含まない（45時間の警告ラインなら、80% は 36:00 を超えた 36:01 から、
#   100% は 45:01 から）。残業時間は勤怠履歴と同じ計算（MonthlyAttendance#total_overtime_minutes）。
# - 判定する月度は、変わった勤務日（date）の月度。締め済みの月度は判定しない（勤怠は変わらないため）。
# - 一度に 80% と 100% の両方を超えた（例：警告ラインを下げた）ときは、2件とも送る（どちらも1回ずつ）。
# - 一度送った段階は、その月度の間は二度と送らない。残業が減って（修正などで）警告ラインを下回り、また超えても送らない。
#   同じ月度に同じ警告を何度も受け取らないようにするため。次の月度になれば、また 80%・100% の順に送る。
# - 同時に判定しても（2つの退勤・承認が同時に届いても）、一意制約で1件だけ作られ、通知も1回だけになる。
#   記録と通知は同じトランザクションで作るので、記録だけがあって通知が無い、ということもない。
# - 通知が作れなかった（例外が起きた）場合でも、元の処理（退勤・承認など）は失敗させない（Notifier.safely）。
class OvertimeAlert < ApplicationRecord
  LEVELS = [ 80, 100 ].freeze

  belongs_to :user

  validates :period_key, presence: true
  validates :level, inclusion: { in: LEVELS }

  # 段階 level の境目（分）。この値を「超えた」ら送る
  def self.threshold_minutes(warning_minutes, level)
    warning_minutes * Rational(level, 100)
  end

  # 残業 overtime_minutes で超えている段階
  def self.crossed_levels(overtime_minutes, warning_minutes)
    LEVELS.select { |level| overtime_minutes > threshold_minutes(warning_minutes, level) }
  end

  # 1人分を判定する。date の月度（締め済みなら何もしない）。作った警告の配列を返す（失敗しても例外は出さず []）
  def self.check(user, date: Date.current, rules: WorkRules.current, now: Time.current)
    period = rules.period_containing(date)
    return [] if period.closed? || !user.active?

    monthly = MonthlyAttendance.for_user(user, period: period, rules: rules, now: now)
    record_crossings(user, period, monthly.total_overtime_minutes, rules.overtime_warning_minutes)
  rescue StandardError => error
    report(error)
    []
  end

  # 有効なユーザー全員の、date の月度を判定する（勤務ルールの変更のあと）。作った警告の配列を返す
  def self.check_all(date: Date.current, rules: WorkRules.current, now: Time.current)
    period = rules.period_containing(date)
    return [] if period.closed?

    users = User.active.order(:id).to_a
    monthlies = MonthlyAttendance.for_users(users, period: period, rules: rules, now: now)
    users.flat_map do |user|
      record_crossings(user, period, monthlies.fetch(user.id).total_overtime_minutes, rules.overtime_warning_minutes)
    end
  rescue StandardError => error
    report(error)
    []
  end

  # 超えている段階のうち、まだ送っていないものの記録と通知を作る
  def self.record_crossings(user, period, overtime_minutes, warning_minutes)
    levels = crossed_levels(overtime_minutes, warning_minutes)
    return [] if levels.empty?

    sent = where(user: user, period_key: period.to_param).pluck(:level)
    (levels - sent).filter_map do |level|
      alert = nil
      delivered = Notifier.safely("残業の警告") do
        alert = create!(user: user, period_key: period.to_param, level: level,
                        overtime_minutes: overtime_minutes, warning_minutes: warning_minutes)
        Notifier.overtime_alert(alert, user: user, period: period)
      rescue ActiveRecord::RecordNotUnique
        # 同時に判定した別の処理が先に作った（その処理が通知も送っている）
        alert = nil
        raise ActiveRecord::Rollback
      end
      # 通知が作れなかった（記録ごと取り消された）ときは、送っていない扱い（次の判定で送り直す）
      delivered ? alert : nil
    end
  end

  def self.report(error)
    Rails.logger.error("[OvertimeAlert] 残業の警告を判定できませんでした: #{error.class}: #{error.message}")
    Rails.error.report(error, handled: true)
  end
  private_class_method :report

  # 警告ラインの表示（「45時間」。分の端数があれば「45:30」）
  def warning_hours_label
    (warning_minutes % 60).zero? ? "#{warning_minutes / 60}時間" : format("%d:%02d", warning_minutes / 60, warning_minutes % 60)
  end
end
