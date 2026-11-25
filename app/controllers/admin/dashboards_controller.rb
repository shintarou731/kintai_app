# 管理者のダッシュボード（F13）：今日の全員の状態（勤務中・休憩中・退勤済み・未出勤・休暇）と人数、
# 対応が必要な事項（承認待ちの申請・前日以前の退勤漏れ・残業の警告）。開くたびに最新の記録から作る
class Admin::DashboardsController < Admin::BaseController
  def show
    @dashboard = AttendanceDashboard.new(admin: current_user, now: Time.current)
  end
end
