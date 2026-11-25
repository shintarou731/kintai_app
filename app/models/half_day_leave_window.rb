# 半休（午前半休・午後半休）が休みにする時間帯。アプリで半休の時間を決める唯一の場所。
#
# - 午前半休：その日の 0:00〜12:00 を休みとする
# - 午後半休：その日の 13:00〜24:00 を休みとする
# - 12:00〜13:00 は昼休みとして、どちらの半休にも含めない
#
# 使う場所
# - シフト作成（F11）：半休の日のシフトが、半休の時間と重なるかの注意（入力画面・割り当て・前週のコピー・シフト表のマス）
# - 予実比較（F12。ShiftCheck）：半休の日の、出勤・退勤の基準の時刻
#   - 午前半休の日に、シフトの開始が 12:00 より前なら、出勤の基準を 13:00（午後の始まり）にする
#   - 午後半休の日に、シフトの終了が 13:00 より後なら、退勤の基準を 12:00（午前の終わり）にする
#   - 基準を動かした結果、働く時間が残らなければ（例：午前半休の日の 9:00〜12:30）、その日は休暇で埋まっているとみなす
module HalfDayLeaveWindow
  MORNING_END_MINUTE = 12 * 60
  AFTERNOON_START_MINUTE = 13 * 60

  module_function

  # 半休が休みにする時間帯（JST の Time の範囲。終わりは含まない）
  def range(leave, date)
    day = date.in_time_zone.beginning_of_day
    if leave.morning?
      day...(day + MORNING_END_MINUTE.minutes)
    else
      (day + AFTERNOON_START_MINUTE.minutes)...(day + 1.day)
    end
  end

  # 「〜12:00」「13:00〜」（画面の説明用）
  def label(leave)
    leave.morning? ? "〜#{Shift.format_clock_time(MORNING_END_MINUTE)}" : "#{Shift.format_clock_time(AFTERNOON_START_MINUTE)}〜"
  end

  # 「午前半休は〜12:00・午後半休は13:00〜」
  def description
    "午前半休は〜#{Shift.format_clock_time(MORNING_END_MINUTE)}・午後半休は#{Shift.format_clock_time(AFTERNOON_START_MINUTE)}〜"
  end

  # starts_at〜ends_at の勤務が、半休の時間と重なるか
  def overlaps?(leave, date, starts_at, ends_at)
    window = range(leave, date)
    starts_at < window.end && window.begin < ends_at
  end

  # 半休の分を除いた、働く時間帯 [開始, 終了]。働く時間が残らなければ nil
  def working_span(leaves, date, starts_at, ends_at)
    day = date.in_time_zone.beginning_of_day
    leaves.each do |leave|
      next unless overlaps?(leave, date, starts_at, ends_at)

      if leave.morning?
        starts_at = [ starts_at, day + AFTERNOON_START_MINUTE.minutes ].max
      else
        ends_at = [ ends_at, day + MORNING_END_MINUTE.minutes ].min
      end
    end
    starts_at < ends_at ? [ starts_at, ends_at ] : nil
  end
end
