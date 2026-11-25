# 1人・1日分の予実比較（F12）：公開済みのシフト（予定）と、打刻（実績）を比べて、遅刻・早退・欠勤を判定する。
# 遅刻・早退・欠勤の判定は、アプリでここだけで行う（勤怠履歴・ホーム・シフトのカレンダー・管理者の予実の確認、
# 今後のダッシュボード（F13）・月次集計（F14）・CSV（F15）もここを使う）。
#
#   check = ShiftCheck.new(shift:, attendance:, leaves:, now:)
#   check.late? / check.early_leave? / check.absent? / check.marks # => [:late, :early_leave]
#
# 予定に使うのは、従業員に公開している内容（published_*）だけ。下書きや、公開後に変えてまだ公開していない内容は使わない。
# 一度も公開していないシフトは「シフトなし」と同じ扱い。
#
# 判定のきまり
# - 時刻は、画面に出る時刻と同じく秒を切り捨てて比べる（Attendance.minutes_between）。許容範囲は GRACE_MINUTES（1分）。
#   - 遅刻：出勤（秒を切り捨て）がシフトの開始より 2分以上後（9:00 開始なら 9:01:59 までは遅刻にしない。9:02:00 から遅刻）
#   - 早退：退勤（秒を切り捨て）がシフトの終了より 2分以上前（18:00 終了なら 17:59:00 以降は早退にしない。17:58:59 は早退）
#   - 欠勤：シフトの終了（半休の日は、半休を除いた働く時間の終わり）を過ぎても、その日の出勤の打刻が無く、休暇も無い
# - 日付をまたぐシフト（22:00〜翌6:00）は、終了を翌日の時刻として比べる。勤怠とは、勤務日（出勤した日）＝シフトの日で突き合わせる。
# - 休憩は判定に使わない（シフトの休憩時間と、実際の休憩の長さ・時刻は比べない）。
# - 全日の休暇（承認済み）の日は、打刻があっても無くても判定しない（:on_leave）。
# - 半休の日は HalfDayLeaveWindow の基準で、出勤・退勤の基準の時刻を動かす。働く時間が残らなければ休暇の日と同じ扱い。
# - 判定がまだ決まらない日は数えない
#   - シフトの終了前で、まだ出勤していない（開始を過ぎていれば :not_clocked_in。ダッシュボードの「遅れ」に使える）
#   - 勤務中・休憩中（早退はまだ決まらない。遅刻は出勤した時点で決まる）
#   - 退勤漏れ（退勤の打刻が無いまま日付が過ぎた）：早退は判定できない（遅刻は判定する）
#   - シフトの開始より前に退勤した（:left_before_start）：シフトの終了を過ぎるまで、早退を決めない
class ShiftCheck
  GRACE_MINUTES = 1

  MARK_ORDER = %i[late early_leave absent].freeze

  attr_reader :shift, :attendance, :leaves, :now

  # leaves … その日にかかる、承認済みで取り消されていない休暇
  def initialize(shift:, attendance:, leaves: [], now: Time.current)
    @shift = shift&.published_once? ? shift : nil
    @attendance = attendance
    @leaves = leaves
    @now = now.in_time_zone
  end

  def scheduled?
    !shift.nil?
  end

  def date
    shift&.work_date || attendance&.work_date
  end

  # 公開中のシフトの開始・終了（JST）
  def scheduled_starts_at
    shift&.published_starts_at
  end

  def scheduled_ends_at
    shift&.published_ends_at
  end

  def full_day_leave
    leaves.find(&:full_day?)
  end

  def half_day_leaves
    leaves.select(&:half_day?)
  end

  # 休暇で、その日に働く時間が残らない（全日の休暇、または半休でシフトの時間がすべて埋まる）
  def covered_by_leave?
    scheduled? && (!full_day_leave.nil? || working_span.nil?)
  end

  # 判定の基準にする出勤・退勤の時刻（半休の日は、半休の分を除く）
  def expected_starts_at
    working_span&.first
  end

  def expected_ends_at
    working_span&.last
  end

  # 半休のため、基準の時刻をシフトの時刻から動かしたか
  def adjusted_for_half_day?
    scheduled? && !covered_by_leave? && [ expected_starts_at, expected_ends_at ] != [ scheduled_starts_at, scheduled_ends_at ]
  end

  # 遅れた分（分）。遅刻でなければ 0
  def late_minutes
    return 0 unless judgeable? && attendance

    minutes = Attendance.minutes_between(expected_starts_at, attendance.clock_in_at)
    minutes > GRACE_MINUTES ? minutes : 0
  end

  # 早く帰った分（分）。早退でなければ 0
  def early_leave_minutes
    return 0 unless judgeable? && attendance&.clocked_out?
    return 0 if left_before_start?

    minutes = Attendance.minutes_between(attendance.clock_out_at, expected_ends_at)
    minutes > GRACE_MINUTES ? minutes : 0
  end

  def late?
    late_minutes.positive?
  end

  def early_leave?
    early_leave_minutes.positive?
  end

  def absent?
    judgeable? && attendance.nil? && now >= expected_ends_at
  end

  # 付いた印（:late / :early_leave / :absent）
  def marks
    MARK_ORDER.select { |mark| public_send(:"#{mark}?") }
  end

  def marked?
    marks.any?
  end

  # その日の予実の状態
  # :no_shift（公開中のシフトが無い）/ :on_leave（休暇で働く時間が無い）/ :absent（欠勤）/
  # :upcoming（開始前でまだ出勤していない）/ :not_clocked_in（開始を過ぎたがまだ出勤していない。終了前）/
  # :working（出勤して、まだ退勤していない）/ :missing_clock_out（退勤漏れ）/
  # :left_before_start（シフトの開始前に退勤した。シフトの終了まで早退を決めない）/ :done（退勤済み）
  def status
    return :no_shift unless scheduled?
    return :on_leave if covered_by_leave?
    return absent? ? :absent : not_clocked_in_status if attendance.nil?
    return left_before_start? ? :left_before_start : :done if attendance.clocked_out?

    attendance.missing_clock_out?(as_of: now) ? :missing_clock_out : :working
  end

  # シフトの開始より前に退勤した勤務で、まだシフトの終了を過ぎていない（例：17:00〜22:00 のシフトの日に、0:24 に出勤・退勤した）。
  # この間は早退を決めない（シフトの開始前に「早退 21:36」と出ないように）。シフトの終了を過ぎたら、ふつうに早退として判定する
  def left_before_start?
    judgeable? && attendance&.clocked_out? && attendance.clock_out_at < expected_starts_at && now < expected_ends_at
  end

  # 早退がまだ判定できない（勤務中・退勤漏れ・シフトの開始前に退勤した）
  def early_leave_pending?
    %i[working missing_clock_out left_before_start].include?(status)
  end

  private

  def judgeable?
    scheduled? && !covered_by_leave?
  end

  def working_span
    return @working_span if defined?(@working_span)

    @working_span = scheduled? ? HalfDayLeaveWindow.working_span(half_day_leaves, shift.work_date, scheduled_starts_at, scheduled_ends_at) : nil
  end

  def not_clocked_in_status
    # 開始の許容範囲（1分）を過ぎたら「未出勤」。それまでは「開始前」
    Attendance.minutes_between(expected_starts_at, now) > GRACE_MINUTES && now >= expected_starts_at ? :not_clocked_in : :upcoming
  end
end
