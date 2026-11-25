# CSV の書き出し（F15）：月次集計の画面から、その月度の従業員別の集計（summary）と、全従業員の日別の明細（daily）を
# ダウンロードする。GET /admin/monthly/exports/summary.csv?month=2026-11（:id は summary か daily）
#
# 値は月次集計（MonthlySummary）と同じものから作るので、画面の表示と一致する（締め済みの月度は締めた時点に固定した値）。
# 管理者だけが使える（Admin::BaseController。従業員が URL を直接開いても、ホームに戻して CSV は渡さない）。
class Admin::MonthlyExportsController < Admin::BaseController
  EXPORTS = { "summary" => MonthlySummaryCsv, "daily" => MonthlyDailyCsv }.freeze

  def show
    rules = WorkRules.current
    now = Time.current
    period = params[:month].present? ? rules.period_from_param(params[:month]) : rules.period_containing(now.to_date)
    if period.nil?
      return redirect_to admin_monthly_summaries_path, alert: "指定された月を書き出せません。月次集計の画面から選び直してください。"
    end

    export = EXPORTS.fetch(params[:id]).new(MonthlySummary.new(period: period, rules: rules, now: now))
    # 勤怠の個人情報なので、ブラウザや途中の経路に残さない
    response.headers["Cache-Control"] = "no-store"
    response.headers["Content-Disposition"] = AttendanceCsv.content_disposition(filename: export.filename, ascii_filename: export.ascii_filename)
    send_data export.to_csv, type: "text/csv; charset=utf-8", disposition: nil
  end
end
