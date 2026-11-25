require "test_helper"

class AttendanceCorrectionRequestTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @user = users(:employee)
  end

  def t(day, hour, min = 0)
    Time.zone.local(2026, 11, day, hour, min)
  end

  def build(date: Date.new(2026, 11, 20), clock_in: "09:00", clock_out: "18:00", clock_out_day: "0", breaks: [],
            reason: "打刻を忘れました", user: @user)
    user.attendance_correction_requests.new(
      target_date: date, clock_in_time: clock_in, clock_out_time: clock_out, clock_out_day: clock_out_day, reason: reason,
      break_inputs: breaks.each_with_index.to_h do |(start, finish, start_day, end_day), index|
        [ index.to_s, { start_time: start, start_day: start_day || "0", end_time: finish, end_day: end_day || "0" } ]
      end
    )
  end

  def work(clock_in, clock_out, breaks: [])
    record = @user.attendances.create!(work_date: clock_in.to_date, clock_in_at: clock_in, clock_out_at: clock_out)
    breaks.each { |from, to| record.breaks.create!(started_at: from, ended_at: to) }
    record
  end

  def errors_of(request)
    travel_to(NOW) { request.valid? }
    request.errors.full_messages
  end

  test "正しい内容なら承認待ちで保存され、勤怠記録は変わらない" do
    travel_to NOW do
      request = build(breaks: [ [ "12:00", "13:00" ], [ "15:00", "15:15" ] ])
      assert request.submit, request.errors.full_messages.inspect
      request.reload
      assert request.pending?
      assert_equal "承認待ち", request.status_label
      assert_equal "打刻修正", request.kind_label
      assert_equal t(20, 9), request.requested_clock_in_at
      assert_equal t(20, 18), request.requested_clock_out_at
      assert_equal [ [ t(20, 12), t(20, 13) ], [ t(20, 15), t(20, 15, 15) ] ], request.breaks.map { |b| [ b.started_at, b.ended_at ] }
      assert_equal 7 * 60 + 45, request.requested_attendance.worked_minutes
      assert_equal 0, Attendance.count
    end
  end

  test "理由は必須（空白だけも不可）で、500文字まで" do
    assert_includes errors_of(build(reason: "")), "理由を入力してください"
    assert_includes errors_of(build(reason: "   ")), "理由を入力してください"
    assert_includes errors_of(build(reason: "あ" * 501)), "理由は500文字以内で入力してください"
    assert_empty errors_of(build(reason: "あ" * 500))
  end

  test "未来の日付は申請できない。今日は申請できる" do
    assert_includes errors_of(build(date: Date.new(2026, 11, 25))), "対象日に未来の日付は指定できません（今日までの日付を選んでください）"
    assert_empty errors_of(build(date: Date.new(2026, 11, 24), clock_in: "09:00", clock_out: "10:00"))
  end

  test "出勤は必須で、時:分の形式（全角も可）" do
    assert_includes errors_of(build(clock_in: "")), "出勤時刻を入力してください"
    assert_includes errors_of(build(clock_in: "25:00")), "出勤時刻は「09:00」のように 時:分 で入力してください"
    assert_includes errors_of(build(clock_in: "9:60")), "出勤時刻は「09:00」のように 時:分 で入力してください"
    assert_includes errors_of(build(clock_in: "abc")), "出勤時刻は「09:00」のように 時:分 で入力してください"
    request = build(clock_in: "０９：００")
    assert_empty errors_of(request)
    assert_equal t(20, 9), request.requested_clock_in_at
    assert_empty errors_of(build(clock_in: "09:00:00"))
  end

  test "退勤が出勤より前・同時刻ならエラー" do
    message = "退勤時刻は出勤時刻より後にしてください（日付をまたいで退勤した場合は、日付で「翌日」を選んでください）"
    assert_includes errors_of(build(clock_in: "09:00", clock_out: "08:00")), message
    assert_includes errors_of(build(clock_in: "09:00", clock_out: "09:00")), message
  end

  test "日付をまたぐ勤務は退勤の日付で「翌日」を選ぶ（22:00 → 翌 02:00）" do
    request = build(clock_in: "22:00", clock_out: "02:00", clock_out_day: "1",
                    breaks: [ [ "23:30", "00:30", "0", "1" ] ])
    assert_empty errors_of(request)
    assert_equal t(21, 2), request.requested_clock_out_at
    assert_equal [ t(20, 23, 30), t(21, 0, 30) ], [ request.breaks.first.started_at, request.breaks.first.ended_at ]
    assert_equal 3 * 60, request.requested_attendance.worked_minutes
  end

  test "勤務は24時間まで（ちょうど24時間は可）" do
    assert_empty errors_of(build(clock_in: "09:00", clock_out: "09:00", clock_out_day: "1"))
    assert_includes errors_of(build(clock_in: "09:00", clock_out: "09:01", clock_out_day: "1")),
                    "退勤時刻は出勤から24時間以内にしてください"
  end

  test "退勤の日付は当日・翌日だけ" do
    assert_includes errors_of(build(clock_out_day: "2")), "退勤の日付は「当日」か「翌日」から選んでください"
    assert_includes errors_of(build(clock_out_day: "abc")), "退勤の日付は「当日」か「翌日」から選んでください"
  end

  test "退勤は過去の日には必須。勤務中でありうる今日の勤務は空欄にできる" do
    assert_includes errors_of(build(clock_out: "")),
                    "退勤時刻を入力してください（退勤の打刻を忘れた日は、実際に退勤した時刻を入力してください）"

    # 今日（記録なし）：出勤だけ申請できる
    today = build(date: Date.new(2026, 11, 24), clock_in: "09:00", clock_out: "")
    assert_empty errors_of(today)
    assert_nil today.requested_clock_out_at

    # 前日 22:00 出勤で、まだ24時間以内（夜勤中）
    assert_empty errors_of(build(date: Date.new(2026, 11, 23), clock_in: "22:00", clock_out: ""))
    # 前日 10:00 出勤は24時間を過ぎているので必須
    assert_not_empty errors_of(build(date: Date.new(2026, 11, 23), clock_in: "10:00", clock_out: ""))

    # 今日の記録がすでに退勤済みなら、退勤は空欄にできない
    work(t(24, 8), t(24, 10))
    assert_not_empty errors_of(build(date: Date.new(2026, 11, 24), clock_in: "08:30", clock_out: ""))
  end

  test "未来の時刻は入力できない" do
    assert_includes errors_of(build(date: Date.new(2026, 11, 24), clock_in: "11:00", clock_out: "")), "出勤時刻に未来の時刻は入力できません"
    assert_includes errors_of(build(date: Date.new(2026, 11, 24), clock_in: "09:00", clock_out: "18:00")), "退勤時刻に未来の時刻は入力できません"
    assert_includes errors_of(build(date: Date.new(2026, 11, 23), clock_in: "22:00", clock_out: "11:00", clock_out_day: "1")),
                    "退勤時刻に未来の時刻は入力できません"
    assert_empty errors_of(build(date: Date.new(2026, 11, 24), clock_in: "09:00", clock_out: "10:30"))
    assert_includes errors_of(build(date: Date.new(2026, 11, 24), clock_in: "09:00", clock_out: "", breaks: [ [ "10:00", "10:45" ] ])),
                    "休憩1に未来の時刻は入力できません"
  end

  test "休憩：開始・終了の片方だけ、終了が開始より前、勤務時間外、重なりはエラー" do
    assert_includes errors_of(build(breaks: [ [ "12:00", "" ] ])), "休憩1の開始時刻と終了時刻を両方入力してください"
    assert_includes errors_of(build(breaks: [ [ "", "13:00" ] ])), "休憩1の開始時刻と終了時刻を両方入力してください"
    assert_includes errors_of(build(breaks: [ [ "12:00", "12:00" ] ])), "休憩1の終了時刻は開始時刻より後にしてください（日付をまたぐ場合は「翌日」を選んでください）"
    assert_includes errors_of(build(breaks: [ [ "13:00", "12:00" ] ])), "休憩1の終了時刻は開始時刻より後にしてください（日付をまたぐ場合は「翌日」を選んでください）"
    assert_includes errors_of(build(breaks: [ [ "8:30", "9:30" ] ])), "休憩1は勤務時間（09:00〜18:00）の中に入れてください"
    assert_includes errors_of(build(breaks: [ [ "17:30", "18:30" ] ])), "休憩1は勤務時間（09:00〜18:00）の中に入れてください"
    assert_includes errors_of(build(clock_in: "22:00", clock_out: "02:00", clock_out_day: "1", breaks: [ [ "02:00", "03:00", "1", "1" ] ])),
                    "休憩1は勤務時間（22:00〜翌02:00）の中に入れてください"
    assert_includes errors_of(build(breaks: [ [ "12:00", "13:00" ], [ "15:00", "16:00" ], [ "12:30", "12:45" ] ])),
                    "休憩1と休憩3の時間が重なっています"
    assert_includes errors_of(build(breaks: [ [ "1200", "13:00" ] ])), "休憩1の時刻は「12:00」のように 時:分 で入力してください"
    assert_includes errors_of(build(breaks: [ [ "12:00", "13:00", "0", "5" ] ])), "休憩1の時刻は「12:00」のように 時:分 で入力してください"
  end

  test "休憩：境目が接する休憩・勤務時間ちょうどの休憩は可。空の行は無視し、行番号は画面の行の順" do
    assert_empty errors_of(build(breaks: [ [ "09:00", "12:00" ], [ "12:00", "13:00" ], [ "17:00", "18:00" ] ]))

    request = build(breaks: [ [ "", "" ], [ "12:00", "" ] ])
    assert_includes errors_of(request), "休憩2の開始時刻と終了時刻を両方入力してください"
    assert_equal Set[2], request.invalid_break_numbers
  end

  test "休憩は10回まで" do
    breaks = (0..10).map { |i| [ format("%02d:00", 7 + i), format("%02d:30", 7 + i) ] }
    request = build(clock_in: "06:00", clock_out: "20:00", breaks: breaks)
    assert_includes errors_of(request), "休憩は10回まで入力できます"
    assert_empty errors_of(build(clock_in: "06:00", clock_out: "20:00", breaks: breaks.first(10)))
  end

  test "前日・翌日の勤務と重なる時刻はエラー" do
    work(t(19, 22), t(20, 2))
    assert_includes errors_of(build(clock_in: "01:00")),
                    "出勤時刻が前日（11/19(木)）の勤務の退勤（02:00）より前です。前日の勤務と重ならない時刻にしてください"
    assert_empty errors_of(build(clock_in: "02:00"))

    work(t(21, 1), t(21, 9))
    assert_includes errors_of(build(clock_in: "22:00", clock_out: "02:00", clock_out_day: "1")),
                    "退勤時刻が翌日（11/21(土)）の勤務の出勤（01:00）より後です。翌日の勤務と重ならない時刻にしてください"
    assert_empty errors_of(build(clock_in: "18:00", clock_out: "01:00", clock_out_day: "1"))
  end

  test "今の記録と同じ内容は申請できない（秒は切り捨てて比べる）" do
    record = work(t(20, 9) + 12.seconds, t(20, 18) + 40.seconds, breaks: [ [ t(20, 12) + 5.seconds, t(20, 13) ] ])
    assert_includes errors_of(build(breaks: [ [ "12:00", "13:00" ] ])), "今の記録と同じ内容です。正しい時刻に直してから申請してください"
    assert_empty errors_of(build(breaks: [ [ "12:00", "12:45" ] ]))
    assert_empty errors_of(build(breaks: []))
    assert record.reload
  end

  test "同じ日の承認待ちの修正申請は重複できない。取り下げ後・他の人・別の日なら出せる" do
    travel_to(NOW) { assert build.submit }
    duplicate = "この日にはすでに承認待ちの修正申請があります。内容を変えたい場合は、その申請を取り下げてから出し直してください"
    assert_includes errors_of(build(clock_in: "09:30")), duplicate
    assert_empty errors_of(build(date: Date.new(2026, 11, 19)))
    assert_empty errors_of(build(user: users(:admin)))

    AttendanceCorrectionRequest.last.withdraw
    assert_empty errors_of(build(clock_in: "09:30"))
  end

  test "同時に届いた2件目は DB の一意制約で防ぎ、submit は false とエラーを返す" do
    travel_to NOW do
      assert build.submit
      second = build(clock_in: "09:30")
      # 検証（重複の確認）を通り抜けた直後に1件目が保存された状況を再現する
      second.define_singleton_method(:must_not_duplicate_pending) { nil }
      assert_no_difference -> { ApprovalRequest.count } do
        assert_not second.submit
      end
      assert_includes second.errors.full_messages, "この日にはすでに承認待ちの修正申請があります。内容を変えたい場合は、その申請を取り下げてから出し直してください"
      assert_equal 0, AttendanceCorrectionBreak.where(approval_request_id: nil).count
    end
  end

  test "承認待ちは取り下げられる。承認済み・却下・取り下げ済みは取り下げできない" do
    travel_to(NOW) { assert build.submit }
    request = AttendanceCorrectionRequest.last
    assert request.withdraw(now: NOW)
    assert request.withdrawn?
    assert_equal NOW, request.withdrawn_at
    assert_not request.withdraw

    %w[approved rejected].each_with_index do |status, index|
      other = build(date: Date.new(2026, 11, 10 + index))
      travel_to(NOW) { assert other.submit }
      other.update_column(:status, status)
      assert_not other.withdraw
      assert_equal status, other.reload.status
      assert_nil other.withdrawn_at
    end
  end

  test "入力欄には今の記録の時刻が入る（日付をまたいだ退勤・休憩は「翌日」）" do
    work(t(20, 22), t(21, 2, 15), breaks: [ [ t(20, 23, 50), t(21, 0, 20) ] ])
    request = AttendanceCorrectionRequest.build_for(@user, Date.new(2026, 11, 20))
    assert_equal [ "22:00", "02:15", "1" ], [ request.clock_in_time, request.clock_out_time, request.clock_out_day ]
    input = request.break_inputs.first
    assert_equal [ "23:50", "0", "00:20", "1" ], [ input.start_time, input.start_day, input.end_time, input.end_day ]

    empty = AttendanceCorrectionRequest.build_for(@user, Date.new(2026, 11, 3))
    assert_nil empty.clock_in_time
    assert_empty empty.break_inputs
  end
end
