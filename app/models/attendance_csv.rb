require "csv"

# 勤怠の CSV（F15）の共通の決まり。従業員別の集計（MonthlySummaryCsv）と日別の明細（MonthlyDailyCsv）で使う。
#
# - 文字コード：UTF-8。先頭に BOM（U+FEFF）を付ける（Excel で開いても日本語が文字化けしないように）
# - 改行：CRLF（Excel・多くの給与ソフトが期待する形。RFC 4180 と同じ）
# - エスケープ：カンマ・改行・ダブルクォートを含む値は、全体をダブルクォートで囲み、中のダブルクォートは2つ重ねる（RFC 4180）
# - 時間：画面と同じ「7:45」（時:分）の列と、給与ソフトに取り込みやすい「分」（465）の列を並べて出す
# - CSV インジェクション対策：文字列の値が「=」「+」「-」「@」、タブ、CR で始まるときは、先頭に「'」を付けて
#   表計算ソフトが数式として扱わないようにする（OWASP の推奨と同じ）。数値（分・回数・日数）は数値のまま出す
module AttendanceCsv
  BOM = "﻿".freeze
  ROW_SEPARATOR = "\r\n".freeze
  FORMULA_PREFIXES = [ "=", "+", "-", "@", "\t", "\r" ].freeze

  module_function

  # header … 見出しの配列、rows … 値の配列の配列
  def generate(header, rows)
    body = CSV.generate(row_sep: ROW_SEPARATOR, encoding: Encoding::UTF_8) do |csv|
      csv << header.map { |value| sanitize(value) }
      rows.each { |row| csv << row.map { |value| sanitize(value) } }
    end
    BOM + body
  end

  # 表計算ソフトで数式として動かないようにする。文字列以外（数値・nil）はそのまま
  def sanitize(value)
    return value unless value.is_a?(String)
    return value unless value.start_with?(*FORMULA_PREFIXES)

    "'#{value}"
  end

  # 時間（分）を「7:45」（時:分）にする。画面の format_duration と同じ書き方
  def duration(minutes)
    minutes = minutes.to_i
    format("%d:%02d", minutes / 60, minutes % 60)
  end

  # 日数（0.5日単位）を数値にする（1 / 1.5）。単位の「日」は見出しに書く
  def days(value)
    value = value.to_r
    value.denominator == 1 ? value.to_i : value.to_f
  end

  # 時刻（JST）を「09:02」にする。画面の format_clock_time と同じ
  def clock(time)
    time && I18n.l(time.in_time_zone, format: :time)
  end

  # 日付を「2026/11/23」にする（Excel が日付として読める形）
  def date(value)
    value.strftime("%Y/%m/%d")
  end

  # ファイル名に入れる月度の名前（「2026年11月度」）。月末締めでも「月度」と書き、未締めなら「_未締め」を付ける
  # （締める前に書き出したファイルと、締めた後のファイルを取り違えないように）
  def period_file_label(period)
    label = "#{period.year}年#{period.month}月度"
    period.closed? ? label : "#{label}_未締め"
  end

  # filename* を読めない古いクライアント向けの、ASCII だけのファイル名に入れる月度（「2026-11」、未締めなら「2026-11_unclosed」）
  def period_ascii_label(period)
    label = period.to_param
    period.closed? ? label : "#{label}_unclosed"
  end

  # Content-Disposition の値。日本語のファイル名は filename*（RFC 6266・5987）で、予備の filename= には ASCII の名前を入れる
  # （Rails の既定では、予備の名前の日本語が「?」に置き換わるため）
  def content_disposition(filename:, ascii_filename:)
    %(attachment; filename="#{ascii_filename}"; filename*=UTF-8''#{ERB::Util.url_encode(filename)})
  end
end
