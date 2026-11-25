# 管理者が勤怠を直接修正した履歴（F14）。誰が（editor）・いつ（created_at）・何を（修正前・修正後の記録）・なぜ（reason）。
#
# - operation：created（勤怠が無い日に新しく作った）/ updated（直した）/ deleted（削除した）
# - before_record / after_record：その時点の勤怠（出勤・退勤・休憩）。作ったときの修正前、削除したときの修正後は nil。
#   形は打刻修正申請の reviewed_record と同じ（AttendanceCorrectionRequest.attendance_from_snapshot で勤怠に戻せる）
# 履歴は書き換えない（修正のたびに1行ずつ増える）。
class AttendanceEdit < ApplicationRecord
  OPERATIONS = %w[created updated deleted].freeze

  belongs_to :user
  belongs_to :editor, class_name: "User"

  serialize :before_record, coder: JSON
  serialize :after_record, coder: JSON

  validates :work_date, :reason, presence: true
  validates :operation, inclusion: { in: OPERATIONS }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  OPERATION_LABELS = { "created" => "新規作成", "updated" => "修正", "deleted" => "削除" }.freeze

  # 勤怠（Attendance）を、履歴に残す形にする。勤怠が無ければ nil
  def self.record_of(attendance)
    return if attendance.nil?

    { "clock_in_at" => attendance.clock_in_at.iso8601, "clock_out_at" => attendance.clock_out_at&.iso8601,
      "breaks" => attendance.breaks.map { |item| [ item.started_at.iso8601, item.ended_at&.iso8601 ] } }
  end

  def operation_label
    OPERATION_LABELS.fetch(operation)
  end

  # 修正前・修正後の勤怠（保存しない Attendance。記録が無ければ nil）
  def before_attendance
    AttendanceCorrectionRequest.attendance_from_snapshot(before_record, user_id: user_id, work_date: work_date)
  end

  def after_attendance
    AttendanceCorrectionRequest.attendance_from_snapshot(after_record, user_id: user_id, work_date: work_date)
  end
end
