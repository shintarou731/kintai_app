# シフトとシフトパターン（F11）に共通の「開始時刻・終了時刻・休憩時間」の入力と確かめ。
#
# - 時刻は DB では「その日の 0:00 からの分」（start_minute / end_minute。0〜1439）で持ち、画面では「9:00」の形で入出力する
#   （start_time / end_time）。全角の数字・コロン（「９：００」）も受け付ける。
# - 終了時刻が開始時刻より前なら、日付をまたいで翌日に終わる（例：22:00〜翌6:00）。終了＝開始は勤務時間が0になるので拒否する。
# - 休憩時間（break_minutes）は分の整数。勤務時間（開始〜終了）より短くする。
module ShiftTimeFields
  extend ActiveSupport::Concern

  MINUTES_PER_DAY = 24 * 60
  TIME_FORMAT = /\A(\d{1,2}):(\d{2})\z/

  included do
    validate :times_must_be_valid
    validates :break_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :break_must_be_shorter_than_shift
  end

  class_methods do
    # 「9:00」「09:00」「９：００」→ 540。解釈できなければ nil（「24:00」「9:60」も nil）
    def parse_clock_time(value)
      match = TIME_FORMAT.match(value.to_s.unicode_normalize(:nfkc).strip)
      return unless match

      hour = match[1].to_i
      minute = match[2].to_i
      (hour * 60) + minute if hour < 24 && minute < 60
    end

    # 540 → 「9:00」
    def format_clock_time(minute)
      format("%d:%02d", minute / 60, minute % 60) unless minute.nil?
    end

    # 開始〜終了の長さ（分）。終了が開始より前なら翌日に終わるとみなす
    def span_minutes(start_minute, end_minute)
      return if start_minute.nil? || end_minute.nil?

      (end_minute - start_minute) % MINUTES_PER_DAY
    end
  end

  %i[start end].each do |edge|
    time_attribute = :"#{edge}_time"
    minute_attribute = :"#{edge}_minute"

    # フォームに表示する値（入力された値があればそのまま返し、エラー時に入力し直せるようにする）
    define_method(time_attribute) do
      raw = instance_variable_get(:"@#{time_attribute}")
      raw.nil? ? self.class.format_clock_time(public_send(minute_attribute)) : raw
    end

    define_method(:"#{time_attribute}=") do |value|
      instance_variable_set(:"@#{time_attribute}", value.to_s)
      public_send(:"#{minute_attribute}=", self.class.parse_clock_time(value))
    end
  end

  # 休憩時間は全角の数字や前後の空白も受け付ける（「６０」→ 60）。空欄は休憩なし（0分）。
  # 数値でない入力（「abc」「1時間」）はそのまま残して「数値で入力してください」のエラーにする
  def break_minutes=(value)
    value = value.unicode_normalize(:nfkc).strip if value.is_a?(String)
    super(value.blank? ? 0 : value)
  end

  # 時刻と休憩の組み合わせ（シフトとパターンが同じ時間帯かを比べる）
  def times_key
    [ start_minute, end_minute, break_minutes ]
  end

  # 日付をまたいで翌日に終わるか（22:00〜翌6:00）
  def overnight?
    !start_minute.nil? && !end_minute.nil? && end_minute < start_minute
  end

  # 開始〜終了の長さ（分。休憩を含む）
  def span_minutes
    self.class.span_minutes(start_minute, end_minute)
  end

  # 実働の予定（分）＝開始〜終了から休憩を引いた時間
  def scheduled_work_minutes
    span = span_minutes
    span && (span - break_minutes.to_i)
  end

  private

  def times_must_be_valid
    { start_time: :start_minute, end_time: :end_minute }.each do |time_attribute, minute_attribute|
      raw = instance_variable_get(:"@#{time_attribute}")
      if public_send(minute_attribute).nil?
        errors.add(time_attribute, raw.blank? ? :blank : :invalid_time)
      end
    end
    return if start_minute.nil? || end_minute.nil?

    errors.add(:end_time, :same_as_start) if start_minute == end_minute
  end

  def break_must_be_shorter_than_shift
    return unless errors[:break_minutes].empty? && errors[:start_time].empty? && errors[:end_time].empty?
    return if break_minutes.nil? || span_minutes.nil? || span_minutes.zero?

    errors.add(:break_minutes, :not_shorter_than_shift, span: self.class.format_clock_time(span_minutes)) if break_minutes >= span_minutes
  end
end
