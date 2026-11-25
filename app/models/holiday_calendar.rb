# 休日（土曜・日曜と日本の国民の祝日）の判定。アプリ全体で休日を判定する唯一の場所。
#
# - 祝日（振替休日・国民の休日を含む）は holiday_jp gem が持つ祝日データで判定する（外部の API にはつながない）。
#   祝日データは内閣府の公表に基づき、gem に同梱された範囲（〜2050年）だけを判定できる。それより先の日は平日の扱いになる。
# - 勤怠履歴（F5）の行の色・祝日名、休暇（F9）の日数の数え方で使う。
#   有給の残日数（F10）、シフト表の列見出し（F11）、シフトのカレンダー（F12）、休日勤務時間（F14）も、ここを使う想定。
# - 管理者が祝日を登録・編集する機能は無い（仕様のスコープ外）。
module HolidayCalendar
  # 日の種類。:holiday（祝日。土曜・日曜が祝日の日も含む）/ :sunday / :saturday / :weekday
  KINDS = %i[holiday sunday saturday weekday].freeze

  module_function

  # 祝日名（例：「勤労感謝の日」「振替休日」「国民の休日」）。祝日でなければ nil
  def holiday_name(date)
    HolidayJp.holidays.holidays[date.to_date]&.name
  end

  # 日本の国民の祝日（振替休日・国民の休日を含む）か
  def holiday?(date)
    !holiday_name(date).nil?
  end

  # 休日（土曜・日曜・祝日）か
  def day_off?(date)
    date = date.to_date
    date.saturday? || date.sunday? || holiday?(date)
  end

  # 休日ではない日（休暇の日数に数える日）か
  def working_day?(date)
    !day_off?(date)
  end

  # 日の種類（表示の色分けに使う）。祝日は曜日より優先する（土曜の祝日は :holiday）
  def day_kind(date)
    date = date.to_date
    if holiday?(date) then :holiday
    elsif date.sunday? then :sunday
    elsif date.saturday? then :saturday
    else :weekday
    end
  end

  # from〜to の祝日（{ 日付 => 祝日名 }、日付の順）
  def holidays_between(from, to)
    (from.to_date..to.to_date).each_with_object({}) do |date, result|
      name = holiday_name(date)
      result[date] = name if name
    end
  end
end
