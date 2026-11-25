# 前日以前の退勤漏れの一覧（F13）。ダッシュボードの件数から開く
class Admin::MissingClockOutsController < Admin::BaseController
  def index
    @now = Time.current
    @rules = WorkRules.current
    @list = MissingClockOutList.new(now: @now)
  end
end
