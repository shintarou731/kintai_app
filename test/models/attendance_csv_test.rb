require "test_helper"

# CSV の書き方の決まり（F15）：BOM・CRLF・エスケープ・CSV インジェクション対策・時間と日数の書き方
class AttendanceCsvTest < ActiveSupport::TestCase
  test "先頭に BOM を付け、改行は CRLF にする" do
    csv = AttendanceCsv.generate(%w[氏名 実働], [ [ "花子", "7:45" ] ])
    assert csv.start_with?("﻿")
    assert_equal "﻿氏名,実働\r\n花子,7:45\r\n", csv
    assert_equal Encoding::UTF_8, csv.encoding
    assert csv.valid_encoding?
  end

  test "カンマ・改行・ダブルクォートを含む値は、ダブルクォートで囲み、中のダブルクォートを重ねる" do
    csv = AttendanceCsv.generate(%w[a b c d], [ [ "山田, 太郎", "1行目\n2行目", %(彼は"至急"と), "普通" ] ])
    assert_equal %(﻿a,b,c,d\r\n"山田, 太郎","1行目\n2行目","彼は""至急""と",普通\r\n), csv
    assert_equal [ [ "山田, 太郎", "1行目\n2行目", %(彼は"至急"と), "普通" ] ], CSV.parse(csv.delete_prefix("﻿"))[1..]
  end

  test "=・+・-・@・タブ・CR で始まる文字列は、先頭に ' を付けて数式にしない。途中にあるもの・数値はそのまま" do
    %w[=SUM(A1:A2) +81-90 -1+1 @cmd].each do |value|
      assert_equal "'#{value}", AttendanceCsv.sanitize(value)
    end
    assert_equal "'\tx", AttendanceCsv.sanitize("\tx")
    assert_equal "'\rx", AttendanceCsv.sanitize("\rx")
    assert_equal "山田=太郎", AttendanceCsv.sanitize("山田=太郎")
    assert_equal "7:45", AttendanceCsv.sanitize("7:45")
    assert_equal 465, AttendanceCsv.sanitize(465)
    assert_nil AttendanceCsv.sanitize(nil)

    csv = AttendanceCsv.generate([ "=見出し" ], [ [ "=1+1" ], [ -5 ] ])
    assert_equal "﻿'=見出し\r\n'=1+1\r\n-5\r\n", csv
  end

  test "時間は画面と同じ「時:分」、日数は数値、時刻は「09:02」、日付は「2026/11/23」" do
    helper = Object.new.extend(ApplicationHelper)
    [ 0, 5, 465, 1705, 6000 ].each { |minutes| assert_equal helper.format_duration(minutes), AttendanceCsv.duration(minutes) }
    assert_equal "28:25", AttendanceCsv.duration(1705)
    assert_equal 1, AttendanceCsv.days(1r)
    assert_equal 0.5, AttendanceCsv.days(1/2r)
    assert_equal 2.5, AttendanceCsv.days(5/2r)
    assert_equal "09:02", AttendanceCsv.clock(Time.zone.local(2026, 11, 23, 9, 2, 59))
    assert_nil AttendanceCsv.clock(nil)
    assert_equal "2026/11/23", AttendanceCsv.date(Date.new(2026, 11, 23))
  end
end
