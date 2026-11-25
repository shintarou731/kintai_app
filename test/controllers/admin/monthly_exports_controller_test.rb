require "test_helper"

# CSV の書き出し（F15）：従業員別の集計・日別の明細の中身（BOM・見出し・改行・エスケープ・数式の扱い）、
# 画面の表示との一致（未締め・締め済み）、ファイル名、権限
class Admin::MonthlyExportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 12, 5, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
  end

  teardown { travel_back }

  def at(date, hour, minute = 0)
    Time.zone.local(date.year, date.month, date.day, hour, minute)
  end

  def nov(day)
    Date.new(2026, 11, day)
  end

  def work!(user, date, from, to, lunch: true)
    attendance = Attendance.create!(user: user, work_date: date, clock_in_at: at(date, *from), clock_out_at: to && at(date, *to))
    attendance.breaks.create!(started_at: at(date, 12), ended_at: at(date, 13)) if lunch
    attendance
  end

  def set_rules!(**values)
    setting = WorkRuleSetting.current
    values.each { |key, value| setting.public_send(:"#{key}=", value) }
    setting.save!
  end

  def build_november
    work!(@employee, nov(10), [ 9, 0 ], [ 18, 0 ])                 # 実働 8:00
    work!(@employee, nov(21), [ 9, 0 ], [ 19, 0 ])                 # 土曜・実働 9:00・残業 1:00
    work!(@employee, nov(24), [ 21, 0 ], nil, lunch: false).update!(clock_out_at: at(nov(25), 1, 0)) # 深夜 3:00・翌日に退勤
    Attendance.create!(user: @employee, work_date: nov(26), clock_in_at: at(nov(26), 9)) # 退勤漏れ
    paid = LeaveRequest.new(user: @employee, leave_type: "paid", day_part: "morning", target_date: nov(27), end_date: nov(27),
                            reason: "通院", status: "approved")
    paid.save!(validate: false)
    absence = LeaveRequest.new(user: @employee, leave_type: "absence", target_date: nov(30), end_date: nov(30), reason: "体調不良", status: "approved")
    absence.save!(validate: false)
    # 11/12 のシフトに 9:05 出勤・17:30 退勤（遅刻 0:05・早退 0:30）、11/13 はシフトがあるのに打刻も休暇も無い（欠勤）
    [ nov(12), nov(13) ].each do |date|
      Shift.create!(user: @employee, work_date: date, start_time: "9:00", end_time: "18:00", break_minutes: 60)
           .update!(published_start_minute: 540, published_end_minute: 1080, published_break_minutes: 60, published_at: at(nov(1), 9))
    end
    work!(@employee, nov(12), [ 9, 5 ], [ 17, 30 ])
  end

  # BOM を取り除いて CSV として読む
  def parsed_csv
    body = response.body.dup.force_encoding(Encoding::UTF_8)
    assert body.start_with?(AttendanceCsv::BOM), "先頭に BOM が付いていること"
    CSV.parse(body.delete_prefix(AttendanceCsv::BOM), headers: true)
  end

  def csv_row(table, column, value)
    table.find { |row| row[column] == value } || flunk("#{column}=#{value} の行がありません")
  end

  def screen_value(selector)
    css_select(selector).first&.text.to_s.squish
  end

  test "従業員別の集計：BOM・CRLF・見出しが付き、値が月次集計の画面の表と一致する（未締め）" do
    build_november
    sign_in_as @admin
    get admin_monthly_export_path("summary", month: "2026-11", format: :csv)
    assert_response :success
    assert_equal "text/csv; charset=utf-8", response.media_type + "; charset=" + response.charset.downcase
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_includes response.body.b, "\r\n".b
    assert_no_match(/[^\r]\n/, response.body.dup.force_encoding(Encoding::UTF_8), "改行はすべて CRLF")

    table = parsed_csv
    assert_equal MonthlySummaryCsv::HEADER, table.headers
    row = csv_row(table, "氏名", "従業 花子")
    assert_equal [ "2026年11月", "2026/11/01〜2026/11/30", "未締め", @employee.id.to_s, "有効" ],
                 [ row["月度"], row["期間"], row["締め"], row["従業員ID"], row["アカウント"] ]
    assert_equal "5", row["出勤日数"]
    assert_equal [ "28:25", "1705" ], [ row["総実働"], row["総実働（分）"] ]
    assert_equal [ "1:00", "60" ], [ row["残業"], row["残業（分）"] ]
    assert_equal [ "3:00", "180" ], [ row["深夜"], row["深夜（分）"] ]
    assert_equal [ "9:00", "540" ], [ row["休日勤務"], row["休日勤務（分）"] ]
    assert_equal [ "0.5", "1", "1", "1", "1", "1" ],
                 [ row["有給取得（日）"], row["遅刻（回）"], row["早退（回）"], row["欠勤（回）"], row["欠勤の休暇（日）"], row["退勤漏れ（件）"] ]
    assert csv_row(table, "氏名", "管理 太郎"), "有効な管理者も出る"
    assert_equal 2, table.size, "表に出す従業員は画面と同じ（記録の無い無効なユーザーは出さない）"

    # 画面の表と同じ値
    get admin_monthly_summaries_path(month: "2026-11")
    base = "[data-testid='monthly-summary-row'][data-user-id='#{@employee.id}']"
    assert_equal "#{row['出勤日数']}日", screen_value("#{base} [data-column='working-days']")
    { "worked" => "総実働", "overtime" => "残業", "night" => "深夜", "holiday" => "休日勤務" }.each do |column, header|
      assert_equal row[header], screen_value("#{base} [data-column='#{column}']"), header
    end
    assert_equal "#{row['有給取得（日）']}日", screen_value("#{base} [data-column='paid-leave']")
    assert_equal "#{row['遅刻（回）']}回", screen_value("#{base} [data-column='late']")
    assert_equal "#{row['早退（回）']}回", screen_value("#{base} [data-column='early-leave']")
    assert_match(/\A#{row['欠勤（回）']}回/, screen_value("#{base} [data-column='absent']"))
    assert_match "ほか欠勤の休暇 #{row['欠勤の休暇（日）']}日", screen_value("#{base} [data-column='absent']")
  end

  test "日別の明細：全従業員の月度のすべての日を1行ずつ出し、値が勤怠履歴の画面と一致する（未締め）" do
    build_november
    sign_in_as @admin
    get admin_monthly_export_path("daily", month: "2026-11", format: :csv)
    assert_response :success
    table = parsed_csv
    assert_equal MonthlyDailyCsv::HEADER, table.headers
    assert_equal 30 * 2, table.size, "2名 × 30日（勤務の無い日の行も出す）"
    hanako = table.select { |row| row["従業員名"] == "従業 花子" }
    assert_equal (1..30).map { |day| format("2026/11/%02d", day) }, hanako.map { |row| row["日付"] }

    day = ->(d) { csv_row(hanako, "日付", format("2026/11/%02d", d)) }
    assert_equal [ "火", nil, "09:00", "18:00", "1:00", "60", "8:00", "480", "0:00", "0", "0:00", "0" ],
                 day.call(10).fields(*%w[曜日 休日 出勤 退勤 休憩 休憩（分） 実働 実働（分） 残業 残業（分） 深夜 深夜（分）])
    assert_equal [ "土", "土曜", "9:00", "1:00", "60" ], day.call(21).fields(*%w[曜日 休日 実働 残業 残業（分）])
    assert_equal [ "21:00", "翌01:00", "3:00", "180" ], day.call(24).fields(*%w[出勤 退勤 深夜 深夜（分）])
    assert_equal [ "09:00", "未打刻", nil, nil, "退勤漏れ" ], day.call(26).fields(*%w[出勤 退勤 実働 実働（分） 状態])
    assert_equal "有給（午前半休）", day.call(27)["休暇"]
    assert_equal "欠勤（全日）", day.call(30)["休暇"]
    assert_equal [ "月", "勤労感謝の日", nil, nil ], day.call(23).fields(*%w[曜日 休日 出勤 実働])
    assert_equal [ "9:00〜18:00", "遅刻 0:05、早退 0:30", "5", "30" ], day.call(12).fields(*%w[予定（シフト） 遅刻・早退・欠勤 遅刻（分） 早退（分）])
    assert_equal [ "欠勤", nil, nil ], day.call(13).fields(*%w[遅刻・早退・欠勤 遅刻（分） 早退（分）])
    assert_equal [ nil, nil, nil, nil, nil ], day.call(2).fields(*%w[出勤 退勤 休憩 実働 状態]), "勤務の無い日は空欄"

    # 管理者の日別の勤怠（勤怠履歴と同じ表）と同じ値
    get admin_monthly_summary_path(@employee, month: "2026-11")
    { 10 => %w[clock-in 出勤], 21 => %w[overtime 残業], 24 => %w[night 深夜], 12 => %w[worked 実働] }.each do |d, (column, header)|
      assert_equal day.call(d)[header], screen_value("tr[data-date='2026-11-#{format('%02d', d)}'] [data-column='#{column}']"), header
    end
    assert_equal "翌01:00", screen_value("tr[data-date='2026-11-24'] [data-column='clock-out']")
  end

  test "締め済みの月度は、締めた時点に固定した値を出す（締め後に勤務ルールを変えても、画面と CSV が一致し変わらない）" do
    build_november
    sign_in_as @admin
    post admin_monthly_closing_path, params: { month: "2026-11" }
    set_rules!(scheduled_work_time: "7:00", closing_day: 20)

    get admin_monthly_export_path("summary", month: "2026-11", format: :csv)
    summary_row = csv_row(parsed_csv, "氏名", "従業 花子")
    assert_equal [ "締め済み", "2026/11/01〜2026/11/30", "1:00", "60" ], summary_row.fields(*%w[締め 期間 残業 残業（分）])
    assert_match(/filename\*=UTF-8''#{Regexp.escape(ERB::Util.url_encode('勤怠集計_2026年11月度.csv'))}/, response.headers["Content-Disposition"])

    get admin_monthly_export_path("daily", month: "2026-11", format: :csv)
    daily = parsed_csv.select { |row| row["従業員名"] == "従業 花子" }
    assert_equal 30, daily.size, "期間は締めた時点のまま（20日締めに変えても 11/1〜11/30）"
    assert_equal [ "8:00", "0:00" ], csv_row(daily, "日付", "2026/11/10").fields(*%w[実働 残業]), "所定 7:00 に変えても残業は 0:00 のまま"
    assert_equal "遅刻 0:05、早退 0:30", csv_row(daily, "日付", "2026/11/12")["遅刻・早退・欠勤"]
    assert_equal "退勤漏れ", csv_row(daily, "日付", "2026/11/26")["状態"]
    assert_equal "有給（午前半休）", csv_row(daily, "日付", "2026/11/27")["休暇"]

    get admin_monthly_summaries_path(month: "2026-11")
    base = "[data-testid='monthly-summary-row'][data-user-id='#{@employee.id}']"
    assert_equal summary_row["総実働"], screen_value("#{base} [data-column='worked']")
    assert_equal summary_row["残業"], screen_value("#{base} [data-column='overtime']")
    get admin_monthly_summary_path(@employee, month: "2026-11")
    assert_equal "0:00", screen_value("tr[data-date='2026-11-10'] [data-column='overtime']")
  end

  test "ファイル名に月度と内容が入り、日本語のファイル名は filename* で渡す。未締めの月度は「未締め」と付く" do
    sign_in_as @admin
    get admin_monthly_export_path("summary", month: "2026-11", format: :csv)
    disposition = response.headers["Content-Disposition"]
    assert disposition.start_with?("attachment;")
    assert_includes disposition, "filename*=UTF-8''#{ERB::Util.url_encode('勤怠集計_2026年11月度_未締め.csv')}"
    assert_match(/filename="[\x20-\x7e]+"/, disposition, "filename= は ASCII だけ（古いブラウザ向け）")
    assert_includes disposition, %(filename="kintai_summary_2026-11_unclosed.csv"), "予備の名前も、月度と内容が分かる ASCII の名前にする"
    assert_not_includes disposition, "%3F"

    get admin_monthly_export_path("daily", month: "2026-11", format: :csv)
    assert_includes response.headers["Content-Disposition"], "filename*=UTF-8''#{ERB::Util.url_encode('勤怠明細_2026年11月度_未締め.csv')}"
    assert_includes response.headers["Content-Disposition"], %(filename="kintai_daily_2026-11_unclosed.csv")

    # 締め済みの月度では、予備の名前にも「unclosed」を付けない
    post admin_monthly_closing_path, params: { month: "2026-10" }
    get admin_monthly_export_path("summary", month: "2026-10", format: :csv)
    assert_includes response.headers["Content-Disposition"], %(filename="kintai_summary_2026-10.csv")
    assert_includes response.headers["Content-Disposition"], ERB::Util.url_encode("勤怠集計_2026年10月度.csv")
    delete admin_monthly_closing_path, params: { month: "2026-10" }

    # 20日締めでは「2026年11月度」（10/21〜11/20）
    set_rules!(closing_day: 20)
    get admin_monthly_export_path("summary", month: "2026-11", format: :csv)
    assert_includes response.headers["Content-Disposition"], ERB::Util.url_encode("勤怠集計_2026年11月度_未締め.csv")
    assert_equal "2026/10/21〜2026/11/20", parsed_csv.first["期間"]
  end

  test "名前のカンマ・改行・ダブルクォートをエスケープし、数式で始まる値は先頭に ' を付ける" do
    @employee.update_column(:name, %(=HYPERLINK("http://example.com","x")))
    users(:inactive_employee).update_columns(active: true, name: %(山田, "太郎"\n2行目))
    work!(@employee, nov(10), [ 9, 0 ], [ 18, 0 ])
    sign_in_as @admin

    get admin_monthly_export_path("summary", month: "2026-11", format: :csv)
    body = response.body.dup.force_encoding(Encoding::UTF_8)
    assert_includes body, %("'=HYPERLINK(""http://example.com"",""x"")")
    assert_includes body, %("山田, ""太郎""\n2行目")
    table = parsed_csv
    assert_equal %('=HYPERLINK("http://example.com","x")), table[1]["氏名"]
    assert_equal %(山田, "太郎"\n2行目), table[2]["氏名"]
    assert_equal 3, table.size

    get admin_monthly_export_path("daily", month: "2026-11", format: :csv)
    assert_equal %('=HYPERLINK("http://example.com","x")), parsed_csv.find { |row| row["日付"] == "2026/11/10" && row["出勤"] }["従業員名"]
  end

  test "月次集計の画面に、この月度の2種類の CSV のダウンロードがある" do
    sign_in_as @admin
    get admin_monthly_summaries_path(month: "2026-11")
    assert_select "[data-testid='csv-export']" do
      assert_select "a[data-testid='csv-summary-link'][href=?][download=?][data-turbo='false']",
                    admin_monthly_export_path("summary", month: "2026-11", format: :csv), "勤怠集計_2026年11月度_未締め.csv"
      assert_select "a[data-testid='csv-daily-link'][href=?][download=?]",
                    admin_monthly_export_path("daily", month: "2026-11", format: :csv), "勤怠明細_2026年11月度_未締め.csv"
      assert_select "[data-testid='csv-open-note']", text: /まだ締めていません/
    end

    post admin_monthly_closing_path, params: { month: "2026-11" }
    get admin_monthly_summaries_path(month: "2026-11")
    assert_select "a[data-testid='csv-summary-link'][download=?]", "勤怠集計_2026年11月度.csv"
    assert_select "[data-testid='csv-open-note']", 0
  end

  test "従業員は URL を直接開いても CSV をダウンロードできない。ログインしていなければログイン画面へ" do
    work!(@employee, nov(10), [ 9, 0 ], [ 18, 0 ])
    get admin_monthly_export_path("summary", month: "2026-11", format: :csv)
    assert_redirected_to login_path

    sign_in_as @employee
    %w[summary daily].each do |kind|
      get admin_monthly_export_path(kind, month: "2026-11", format: :csv)
      assert_redirected_to root_path
      assert_nil response.headers["Content-Disposition"]
      assert_not_includes response.body, "従業 花子"
    end
  end

  test "不正な月・種類は書き出さない" do
    sign_in_as @admin
    get admin_monthly_export_path("summary", month: "2026-13", format: :csv)
    assert_redirected_to admin_monthly_summaries_path
    get "/admin/monthly/exports/other.csv?month=2026-11"
    assert_response :not_found
  end

  test "拡張子が .csv でない URL（.json・拡張子なしなど）は 404 で、CSV を返さない" do
    sign_in_as @admin
    %w[/admin/monthly/exports/summary.json /admin/monthly/exports/summary /admin/monthly/exports/daily.html].each do |path|
      get "#{path}?month=2026-10"
      assert_response :not_found, path
      assert_nil response.headers["Content-Disposition"], path
    end
  end
end
