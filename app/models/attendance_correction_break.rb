# 打刻修正申請で申請する休憩（1回分）。開始・終了ともに必須（申請では休憩中の休憩は扱わない）。
class AttendanceCorrectionBreak < ApplicationRecord
  belongs_to :correction_request, class_name: "AttendanceCorrectionRequest", foreign_key: :approval_request_id,
                                  inverse_of: :breaks

  validates :started_at, :ended_at, presence: true

  # 休憩時間（分）。勤怠と同じく分単位で数える
  def duration_minutes
    Attendance.minutes_between(started_at, ended_at)
  end
end
