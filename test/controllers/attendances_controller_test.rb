require "test_helper"

class AttendancesControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:employee)
  end

  def t(day, hour, min = 0, month: 11)
    Time.zone.local(2026, month, day, hour, min)
  end

  def work(clock_in, clock_out, breaks: [], user: @user)
    record = user.attendances.create!(work_date: clock_in.to_date, clock_in_at: clock_in, clock_out_at: clock_out)
    breaks.each { |from, to| record.breaks.create!(started_at: from, ended_at: to) }
    record
  end

  def row(date)
    "tr[data-date='#{date.iso8601}']"
  end

  test "未ログインではログイン画面へ移動する" do
    get attendances_path
    assert_redirected_to login_path
  end

  test "初期表示は今月で、1日〜末日が1行ずつ並ぶ" do
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_response :success
      assert_select "[data-testid='period-label']", text: /2026年11月/
      assert_select "[data-testid='period-label'] .badge", "今月"
      assert_select "[data-testid='period-range']", "11/1(日)〜11/30(月)"
      assert_select "[data-testid='attendance-days'] tbody tr", 30
      assert_select "[data-testid='attendance-days'] tbody tr:first-child th", /11\/1\(日\)/
      assert_select "[data-testid='attendance-days'] tbody tr:last-child th", /11\/30\(月\)/
      assert_select "#{row(Date.new(2026, 11, 24))}.history-row--today"
      assert_select "[data-testid='current-month']", count: 0
    end
  end

  test "ヘッダーのナビに「勤怠履歴」があり、表示中は選択状態になる" do
    sign_in_as @user
    get root_path
    assert_select ".header__nav a.nav__link[href='#{attendances_path}']", "勤怠履歴"
    get attendances_path
    assert_select ".header__nav a.nav__link.is-active[href='#{attendances_path}'][aria-current='page']", "勤怠履歴"
  end

  test "各日の出勤・退勤・休憩・実働・残業・深夜を表示し、勤務の無い日は空欄" do
    work(t(2, 9), t(2, 18, 45), breaks: [ [ t(2, 12), t(2, 13) ] ])
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      date = Date.new(2026, 11, 2)
      assert_select "#{row(date)} td[data-column='clock-in']", "09:00"
      assert_select "#{row(date)} td[data-column='clock-out']", "18:45"
      assert_select "#{row(date)} td[data-column='break']", "1:00"
      assert_select "#{row(date)} td[data-column='worked']", "8:45"
      assert_select "#{row(date)} td[data-column='overtime']", "0:45"
      assert_select "#{row(date)} td[data-column='night']", "0:00"

      empty = Date.new(2026, 11, 3)
      assert_select "#{row(empty)}.history-row--empty"
      %w[clock-in clock-out break worked overtime night].each do |column|
        assert_select "#{row(empty)} td[data-column='#{column}']", ""
      end
    end
  end

  test "土曜・日曜の行は色分け用のクラスが付く" do
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "#{row(Date.new(2026, 11, 7))}.history-row--saturday"
      assert_select "#{row(Date.new(2026, 11, 8))}.history-row--sunday"
      assert_select "#{row(Date.new(2026, 11, 9))}:not(.history-row--saturday):not(.history-row--sunday)"
      assert_select "tbody tr.history-row--saturday", 4
      assert_select "tbody tr.history-row--sunday", 5
    end
  end

  test "祝日の行は日曜と同じ赤（history-row--holiday）で、祝日名が出る（2026年11月23日は勤労感謝の日）" do
    travel_to t(25, 10) do
      sign_in_as @user
      get attendances_path
      holiday = row(Date.new(2026, 11, 23))
      assert_select "#{holiday}.history-row--holiday.history-row--day-off"
      assert_select "#{holiday}:not(.history-row--saturday):not(.history-row--sunday)"
      assert_select "#{holiday} [data-testid='holiday-name']", "勤労感謝の日"
      assert_select "#{row(Date.new(2026, 11, 3))} [data-testid='holiday-name']", "文化の日"
      assert_select "tbody tr.history-row--holiday", 2
      assert_select "tbody [data-testid='holiday-name']", 2
      # 祝日ではない土曜・日曜・平日には祝日名が出ない
      assert_select "#{row(Date.new(2026, 11, 21))}.history-row--saturday [data-testid='holiday-name']", 0
      assert_select "#{row(Date.new(2026, 11, 22))}.history-row--sunday [data-testid='holiday-name']", 0
      assert_select "#{row(Date.new(2026, 11, 24))}:not(.history-row--day-off)"
      assert_select ".history-legend", /日曜・祝日/
    end
  end

  test "振替休日・国民の休日はその名前で、土曜の祝日は土曜ではなく祝日として示す" do
    travel_to t(25, 10) do
      sign_in_as @user
      get attendances_path(month: "2026-05")
      assert_select "#{row(Date.new(2026, 5, 6))}.history-row--holiday [data-testid='holiday-name']", "振替休日"
      # 日曜の祝日（憲法記念日）も祝日として示す
      assert_select "#{row(Date.new(2026, 5, 3))}.history-row--holiday:not(.history-row--sunday) [data-testid='holiday-name']", "憲法記念日"

      get attendances_path(month: "2026-09")
      assert_select "#{row(Date.new(2026, 9, 22))}.history-row--holiday [data-testid='holiday-name']", "国民の休日"

      get attendances_path(month: "2028-01")
      saturday_holiday = row(Date.new(2028, 1, 1))
      assert_select "#{saturday_holiday}.history-row--holiday:not(.history-row--saturday) [data-testid='holiday-name']", "元日"
      assert_select "#{row(Date.new(2028, 1, 8))}.history-row--saturday"
    end
  end

  test "前月・翌月へ移動でき、今月以外では「今月」に戻るリンクが出る" do
    work(t(15, 9, month: 10), t(15, 18, month: 10))
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "a[data-testid='previous-month'][href=?]", attendances_path(month: "2026-10"), text: "← 前月"
      assert_select "a[data-testid='next-month'][href=?]", attendances_path(month: "2026-12"), text: "翌月 →"

      get attendances_path(month: "2026-10")
      assert_select "[data-testid='period-label']", "2026年10月"
      assert_select "[data-testid='attendance-days'] tbody tr", 31
      assert_select "a[data-testid='current-month'][href='#{attendances_path}']", "今月"
      assert_select "[data-testid='total-days']", "1日"
      assert_select "tbody tr.history-row--today", 0

      get attendances_path(month: "2027-02")
      assert_select "[data-testid='period-label']", "2027年2月"
      assert_select "[data-testid='attendance-days'] tbody tr", 28
    end
  end

  test "不正な月を指定すると今月にリダイレクトしてエラーを表示する" do
    sign_in_as @user
    [ "2026-13", "abc", "1999-01" ].each do |value|
      get attendances_path(month: value)
      assert_redirected_to attendances_path
      follow_redirect!
      assert_select ".flash--alert", "指定された月を表示できません。今月の勤怠履歴を表示します。"
    end
  end

  test "画面上部に出勤日数・総実働・総残業・深夜時間の合計（7:30 ＋ 8:45 ＝ 16:15）" do
    work(t(2, 9), t(2, 16, 30))                                        # 7:30
    work(t(3, 9), t(3, 18, 45), breaks: [ [ t(3, 12), t(3, 13) ] ])    # 8:45（残業 0:45）
    work(t(5, 20), t(6, 2), breaks: [ [ t(5, 23, 30), t(6, 0, 30) ] ]) # 5:00（深夜 3:00）
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='total-days']", "3日"
      assert_select "[data-testid='total-worked']", "21:15"
      assert_select "[data-testid='total-overtime']", "0:45"
      assert_select "[data-testid='total-night']", "3:00"
      assert_select "[data-testid='monthly-totals']", /所定労働時間（8:00）/
      # 日付をまたいだ勤務は出勤した日の行に出て、退勤に「翌」が付く
      assert_select "#{row(Date.new(2026, 11, 5))} td[data-column='clock-out']", "翌02:00"
      assert_select "#{row(Date.new(2026, 11, 6))}.history-row--empty"
    end
  end

  test "24時間を超える合計も「160:30」の形で表示する" do
    (2..21).each { |day| work(t(day, 9), t(day, 17, 1)) } # 8:01 × 20日 ＝ 160:20
    work(t(22, 9), t(22, 9, 10))                         # 0:10
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='total-days']", "21日"
      assert_select "[data-testid='total-worked']", "160:30"
      assert_select "[data-testid='total-overtime']", "0:20"
    end
  end

  test "退勤漏れの日は赤い印と警告が出て、時間は合計に含めない" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 9))
    work(t(11, 9), t(11, 18))
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      missing = row(Date.new(2026, 11, 10))
      assert_select "#{missing}.history-row--missing"
      assert_select "#{missing} .badge--danger", "退勤漏れ"
      assert_select "#{missing} td[data-column='clock-out']", "未打刻"
      assert_select "#{missing} td[data-column='worked']", "—"
      assert_select "[data-testid='missing-clock-out-notice']", /退勤漏れが 1 日あります/
      assert_select "[data-testid='missing-clock-out-notice']", /11\/10\(火\)/
      assert_select "[data-testid='total-days']", "2日"
      assert_select "[data-testid='total-worked']", "9:00"
    end
  end

  test "勤務日が今日の退勤していない勤務は勤務中として表示時点までの時間を出す" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10))
    travel_to t(10, 23, 59) do
      sign_in_as @user
      get attendances_path
      date = row(Date.new(2026, 11, 10))
      assert_select "#{date}.history-row--missing", 0
      assert_select "#{date} [data-testid='day-status']", "勤務中"
      assert_select "#{date} td[data-column='worked']", "13:59"
      assert_select "[data-testid='in-progress-note']", /11\/10\(火\) の勤務は勤務中です。/
      assert_select "[data-testid='missing-clock-out-notice']", 0
    end
  end

  test "勤務日が過ぎて出勤から24時間以内の勤務は退勤漏れとし、ホームから退勤できることを案内する" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10))
    work(t(9, 9), t(9, 19))
    travel_to t(11, 9, 59) do
      sign_in_as @user
      get attendances_path
      date = row(Date.new(2026, 11, 10))
      assert_select "#{date}.history-row--missing"
      assert_select "#{date} [data-testid='day-status'].badge--danger", "退勤漏れ"
      assert_select "#{date} [data-testid='clock-out-open-hint']", "ホームで退勤可（〜11/11(水) 10:00）"
      assert_select "#{date} td[data-column='clock-out']", "未打刻"
      assert_select "#{date} td[data-column='worked']", "—"
      assert_select "#{date} td[data-column='overtime']", "—"
      assert_select "[data-testid='missing-clock-out-notice']", /退勤漏れが 1 日あります/
      assert_select "[data-testid='missing-clock-out-open']",
                    /11\/10\(火\) は退勤の打刻がまだありません。\s*出勤から24時間以内のため、11\/11\(水\) 10:00 まではホームから退勤を打刻できます。/
      assert_select "[data-testid='missing-clock-out-open'] a[href='#{root_path}']", "ホームで退勤する"
      assert_select "[data-testid='missing-clock-out-closed']", 0
      assert_select "[data-testid='in-progress-note']", 0
      assert_select "[data-testid='total-days']", "2日"
      assert_select "[data-testid='total-worked']", "10:00"
      assert_select "[data-testid='total-overtime']", "2:00"
      assert_select "[data-testid='total-night']", "0:00"
    end
  end

  test "出勤から24時間を過ぎた退勤漏れは、ホームから退勤できる案内を出さず修正申請を案内する" do
    @user.attendances.create!(work_date: Date.new(2026, 11, 10), clock_in_at: t(10, 10))
    travel_to Time.zone.local(2026, 11, 11, 10, 0, 1) do
      sign_in_as @user
      get attendances_path
      date = row(Date.new(2026, 11, 10))
      assert_select "#{date} [data-testid='day-status']", "退勤漏れ"
      assert_select "#{date} [data-testid='clock-out-open-hint']", 0
      assert_select "[data-testid='missing-clock-out-open']", 0
      assert_select "[data-testid='missing-clock-out-closed']", /11\/10\(火\)\s*は退勤の打刻がありません。.*修正申請で、実際に退勤した時刻を申請してください。/m
    end
  end

  test "勤怠履歴の実働・休憩はホーム画面の表示と一致する" do
    work(t(24, 8, 58), t(24, 18, 3), breaks: [ [ t(24, 12, 0), t(24, 12, 59) ], [ t(24, 15), t(24, 15, 10) ] ])
    travel_to t(24, 20) do
      sign_in_as @user
      get root_path
      home_worked = css_select("[data-testid='worked-time']").text.strip
      home_break = css_select("[data-testid='break-time']").text.strip[/\d+:\d{2}/]

      get attendances_path
      date = row(Date.new(2026, 11, 24))
      assert_equal "7:56", home_worked
      assert_select "#{date} td[data-column='worked']", home_worked
      assert_select "#{date} td[data-column='break']", home_break
    end
  end

  test "自分の勤怠だけを表示する" do
    work(t(2, 9), t(2, 18), user: users(:admin))
    travel_to t(24, 10) do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='total-days']", "0日"
      assert_select "#{row(Date.new(2026, 11, 2))}.history-row--empty"
    end
  end

  test "ホーム画面から勤怠履歴へのリンクがある" do
    sign_in_as @user
    get root_path
    assert_select ".quick-links a[href='#{attendances_path}']", "今月の勤怠履歴を見る"
  end

  test "開発用の注意書きは時計（clock コントローラ）で時刻が進む" do
    DevelopmentClock.offset = 0
    travel_to t(24, 10, 15) do
      sign_in_as @user
      get attendances_path
      assert_select "[data-testid='dev-clock-banner'][data-controller='clock'][data-clock-reload-on-date-change-value='false']"
      assert_select "[data-testid='dev-clock-banner'] [data-clock-target='time']", "10:15:00"
      assert_select "[data-testid='dev-clock-banner'] [data-clock-target='date']", "2026年11月24日(火)"
    end
  ensure
    DevelopmentClock.offset = nil
  end
end
