require "application_system_test_case"

# CSV の書き出し（F15）をブラウザで確かめる：月次集計の画面に2つのダウンロードがあり、ブラウザが受け取るファイル名・
# 中身（BOM 付きの UTF-8）が正しい／1400px・375px で横スクロールが出ない
class MonthlyExportsTest < ApplicationSystemTestCase
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 12, 5, 10, 0)

  # リンク先をブラウザの fetch で取り、Content-Disposition と、先頭のバイト・1行目を返す
  FETCH_SCRIPT = <<~JS.freeze
    const done = arguments[arguments.length - 1];
    fetch(arguments[0], { credentials: "same-origin" }).then(async (response) => {
      const bytes = new Uint8Array(await response.arrayBuffer());
      const text = new TextDecoder("utf-8", { ignoreBOM: true }).decode(bytes);
      done({ status: response.status, disposition: response.headers.get("Content-Disposition"),
             head: Array.from(bytes.slice(0, 3)), firstLine: text.split("\\r\\n")[0], secondLine: text.split("\\r\\n")[1] });
    }).catch((error) => done({ error: String(error) }));
  JS

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    date = Date.new(2026, 11, 10)
    attendance = Attendance.create!(user: @employee, work_date: date, clock_in_at: date.in_time_zone.change(hour: 9),
                                    clock_out_at: date.in_time_zone.change(hour: 19))
    attendance.breaks.create!(started_at: date.in_time_zone.change(hour: 12), ended_at: date.in_time_zone.change(hour: 13))
  end

  teardown do
    reset_size
    travel_back
  end

  test "月次集計の画面から、従業員別の集計と日別の明細を、月度の入ったファイル名で書き出せる" do
    log_in_as @admin
    visit admin_monthly_summaries_path(month: "2026-11")
    within("[data-testid='csv-export']") do
      assert_text "CSVで書き出す（2026年11月）"
      assert_selector "[data-testid='csv-open-note']", text: "まだ締めていません"
    end
    assert_no_horizontal_scroll
    page.execute_script("document.querySelector(\"[data-testid='csv-export']\").scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/screenshots/csv-export-1400.png"))

    summary_link = find("[data-testid='csv-summary-link']")
    assert_equal "勤怠集計_2026年11月度_未締め.csv", summary_link["download"]
    result = page.evaluate_async_script(FETCH_SCRIPT, summary_link["href"])
    assert_equal 200, result["status"]
    assert_equal [ 0xEF, 0xBB, 0xBF ], result["head"], "UTF-8 の BOM"
    assert_includes result["disposition"], "filename*=UTF-8''#{ERB::Util.url_encode('勤怠集計_2026年11月度_未締め.csv')}"
    assert result["firstLine"].start_with?("﻿月度,期間,締め,従業員ID,氏名")
    assert_includes result["secondLine"], "管理 太郎"

    daily_link = find("[data-testid='csv-daily-link']")
    result = page.evaluate_async_script(FETCH_SCRIPT, daily_link["href"])
    assert_includes result["disposition"], ERB::Util.url_encode("勤怠明細_2026年11月度_未締め.csv")
    assert result["firstLine"].start_with?("﻿従業員ID,従業員名,日付,曜日")
  end

  test "375px でも書き出しのボタンが押せ、横スクロールが出ない" do
    resize_to(375)
    log_in_as @admin
    visit admin_monthly_summaries_path(month: "2026-11")
    assert_selector "[data-testid='csv-summary-link']", visible: true
    assert_selector "[data-testid='csv-daily-link']", visible: true
    assert_no_horizontal_scroll
    page.execute_script("document.querySelector(\"[data-testid='csv-export']\").scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/screenshots/csv-export-375.png"))
  end

  private

  def resize_to(width)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
  end

  def reset_size
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def assert_no_horizontal_scroll
    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    client_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator scroll_width, :<=, client_width
  end
end
