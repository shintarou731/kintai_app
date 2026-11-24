# 管理者が「設定」画面で保存する勤務ルール（F6）。組織で1件だけ持つ。
#
# 計算（勤怠履歴など）では、このモデルを直接使わず WorkRules.current（値だけを持つオブジェクト）を使う。
# 行がまだ無いあいだは、初期値（所定 8:00・休憩 1:00・月末締め・警告ライン 45時間）で動く。
#
# 所定労働時間・標準の休憩時間は、画面では「8:00」のような時:分の文字列で受け取り、分に直して保存する。
class WorkRuleSetting < ApplicationRecord
  # 選べる締め日（nil は月末締め）
  CLOSING_DAYS = [ 15, 20, 25 ].freeze

  # 時:分で入力する項目 => [保存する列（分）, 入力できる範囲（分）]
  # 所定労働時間は 0:01〜24:00、標準の休憩時間は 0:00〜24:00
  DURATION_ATTRIBUTES = {
    scheduled_work_time: [ :scheduled_work_minutes, (1..(24 * 60)) ],
    standard_break_time: [ :standard_break_minutes, (0..(24 * 60)) ]
  }.freeze

  # 月の残業時間の警告ライン（時間）。1か月の時間数（31日×24時間）まで
  OVERTIME_WARNING_HOURS_RANGE = (1..(31 * 24))

  # 時:分（「8:00」「7:30」「08:00」）、または時だけ（「8」）
  DURATION_FORMAT = /\A(\d+)(?::(\d{2}))?\z/

  # 初期値は WorkRules の初期値にそろえる（列の既定値と同じ）
  attribute :scheduled_work_minutes, :integer, default: WorkRules::DEFAULT_SCHEDULED_WORK_MINUTES
  attribute :standard_break_minutes, :integer, default: WorkRules::DEFAULT_STANDARD_BREAK_MINUTES
  attribute :overtime_warning_hours, :integer, default: WorkRules::DEFAULT_OVERTIME_WARNING_HOURS

  belongs_to :updated_by, class_name: "User", optional: true

  validate :durations_must_be_valid
  validates :overtime_warning_hours, numericality: { only_integer: true,
                                                     greater_than_or_equal_to: OVERTIME_WARNING_HOURS_RANGE.min,
                                                     less_than_or_equal_to: OVERTIME_WARNING_HOURS_RANGE.max }
  validate :closing_day_must_be_selectable

  # 保存された設定（無ければ初期値の未保存のレコード）
  def self.current
    order(:id).first || new
  end

  # 締め日の選択肢（表示名, 値）。値の "" は月末締め
  def self.closing_day_options
    [ [ "月末", "" ] ] + CLOSING_DAYS.map { |day| [ "#{day}日", day.to_s ] }
  end

  # 締め日の表示名（「月末」「20日」）
  def self.closing_day_label(closing_day)
    closing_day ? "#{closing_day}日" : "月末"
  end

  # 「8:00」→ 480。解釈できなければ nil（マイナスや「8:60」も nil）
  def self.parse_duration(value)
    match = DURATION_FORMAT.match(normalize_duration(value))
    return unless match

    minutes = match[2].to_i
    return if minutes >= 60

    (match[1].to_i * 60) + minutes
  end

  # 全角の数字・コロン（「８：００」）や前後の空白を半角にそろえる。全角のマイナス記号も「-」にする
  def self.normalize_duration(value)
    value.to_s.unicode_normalize(:nfkc).strip.tr("−", "-")
  end

  def self.format_duration(minutes)
    format("%d:%02d", minutes / 60, minutes % 60) unless minutes.nil?
  end

  DURATION_ATTRIBUTES.each do |time_attribute, (minutes_attribute, _range)|
    # フォームに表示する値（入力された値があればそのまま返し、エラー時に入力し直せるようにする）
    define_method(time_attribute) do
      raw = instance_variable_get(:"@#{time_attribute}")
      raw.nil? ? self.class.format_duration(public_send(minutes_attribute)) : raw
    end

    define_method(:"#{time_attribute}=") do |value|
      instance_variable_set(:"@#{time_attribute}", value.to_s)
      public_send(:"#{minutes_attribute}=", self.class.parse_duration(value))
    end
  end

  def closing_day_label
    self.class.closing_day_label(closing_day)
  end

  # 計算に使う勤務ルール
  def to_work_rules
    WorkRules.new(scheduled_work_minutes: scheduled_work_minutes,
                  standard_break_minutes: standard_break_minutes,
                  closing_day: closing_day,
                  overtime_warning_hours: overtime_warning_hours)
  end

  CHANGE_LABELS = {
    scheduled_work_minutes: "1日の所定労働時間",
    standard_break_minutes: "標準の休憩時間",
    closing_day: "締め日",
    overtime_warning_hours: "残業時間の警告ライン"
  }.freeze

  # 直前の保存で変わった項目（例：「1日の所定労働時間 8:00 → 7:00」）。
  # 初めて保存したときは、初期値からの変化として数える
  def saved_change_descriptions
    defaults = self.class.new
    CHANGE_LABELS.filter_map do |attribute, label|
      next unless saved_change_to_attribute?(attribute)

      before, after = saved_change_to_attribute(attribute)
      before = defaults.public_send(attribute) if previously_new_record?
      next if before == after

      "#{label} #{format_value(attribute, before)} → #{format_value(attribute, after)}"
    end
  end

  private

  def format_value(attribute, value)
    case attribute
    when :closing_day then self.class.closing_day_label(value)
    when :overtime_warning_hours then "#{value}時間"
    else self.class.format_duration(value)
    end
  end

  # 時:分の入力を確かめる。エラーは入力欄（scheduled_work_time など）に付ける
  def durations_must_be_valid
    DURATION_ATTRIBUTES.each do |time_attribute, (minutes_attribute, range)|
      raw = instance_variable_get(:"@#{time_attribute}")
      minutes = public_send(minutes_attribute)
      normalized = self.class.normalize_duration(raw.nil? ? self.class.format_duration(minutes) : raw)

      if normalized.empty?
        errors.add(time_attribute, :blank)
      elsif normalized.start_with?("-")
        errors.add(time_attribute, :negative_duration)
      elsif minutes.nil?
        errors.add(time_attribute, :invalid_duration)
      elsif minutes < range.min
        errors.add(time_attribute, :too_short_duration)
      elsif minutes > range.max
        errors.add(time_attribute, :too_long_duration, max: self.class.format_duration(range.max))
      end
    end
  end

  # 選択肢以外の締め日（画面を通さずに送られた値など）は保存しない
  def closing_day_must_be_selectable
    raw = closing_day_before_type_cast
    return if raw.blank? && closing_day.nil?
    return if CLOSING_DAYS.include?(closing_day) && raw.to_s == closing_day.to_s

    errors.add(:closing_day, :inclusion)
  end
end
