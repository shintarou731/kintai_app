require "test_helper"
require "minitest/mock"

class LeaveRequestTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-24 は火曜日。11/26(木) 11/27(金) 11/28(土) 11/29(日) 11/30(月)
  NOW = Time.zone.local(2026, 11, 24, 10, 30)

  setup do
    @employee = users(:employee)
    @admin = users(:admin)
    travel_to NOW
  end

  teardown { travel_back }

  def d(day, month: 11)
    Date.new(2026, month, day)
  end

  def build(user: @employee, from: d(26), to: d(26), type: "paid", part: "full_day", reason: "私用のため")
    user.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: part, reason: reason)
  end

  def submit!(**options)
    leave = build(**options)
    assert leave.submit, leave.errors.full_messages.inspect
    leave
  end

  def approve!(leave, at: NOW)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: at)
    leave
  end

  # ---- 入力の確かめ ----

  test "種類・期間・区分・理由を入れて申請でき、承認待ちになる" do
    leave = submit!(from: d(26), to: d(27), type: "special", reason: "  慶弔のため  ")

    assert leave.pending?
    assert_equal "休暇", leave.kind_label
    assert_equal "特別休暇", leave.leave_type_label
    assert_equal "全日", leave.day_part_label
    assert_equal "慶弔のため", leave.reason
    assert_equal "11/26(木)〜11/27(金)", leave.target_label
    assert_equal "特別休暇（全日）", leave.day_label
  end

  test "種類・理由が無い、区分が不正な申請はできない" do
    leave = build(type: nil, part: "evening", reason: " ")

    assert_not leave.submit
    assert_includes leave.errors.full_messages, "休暇の種類を「有給休暇」「特別休暇」「欠勤」から選んでください"
    assert_includes leave.errors.full_messages, "区分を「全日」「午前半休」「午後半休」から選んでください"
    assert_includes leave.errors.full_messages, "理由を入力してください"
    assert_equal 0, LeaveRequest.count
  end

  test "終了日が開始日より前の期間は申請できない" do
    leave = build(from: d(27), to: d(26))

    assert_not leave.submit
    assert_equal [ "終了日は開始日と同じか、開始日より後の日付にしてください" ], leave.errors.full_messages
  end

  test "開始日が空・日付として読めない場合は申請できない" do
    leave = @employee.leave_requests.new(target_date: "2026-13-40", end_date: "", leave_type: "paid", reason: "x")

    assert_not leave.submit
    assert_includes leave.errors.full_messages, "開始日を入力してください"
  end

  test "終了日が空なら開始日と同じ1日の休暇になる" do
    leave = submit!(from: d(26), to: nil)

    assert_equal d(26), leave.end_date
    assert leave.single_day?
    assert_equal "11/26(木)", leave.target_label
  end

  test "半休は1日だけ指定でき、2日以上の期間では申請できない" do
    assert submit!(from: d(26), to: d(26), part: "morning").morning?

    leave = build(from: d(30), to: d(1, month: 12), part: "afternoon")
    assert_not leave.submit
    assert_equal [ "区分が半休のときは、1日だけ指定できます（開始日と終了日を同じ日にしてください）" ], leave.errors.full_messages
  end

  test "1回の申請は31日まで" do
    assert build(from: d(30), to: d(30) + 30).valid?
    leave = build(from: d(30), to: d(30) + 31)

    assert_not leave.submit
    assert_equal [ "終了日までの期間は31日以内にしてください（長い休暇は分けて申請してください）" ], leave.errors.full_messages
  end

  test "過去の日付も申請できる（1年前まで）。1年より前・1年より先は申請できない" do
    assert submit!(from: d(20), to: d(20), type: "absence", reason: "体調不良で欠勤しました").pending?
    assert build(from: Date.current - 1.year, to: Date.current - 1.year + 1, type: "absence").valid?

    too_old = build(from: Date.current - 1.year - 1, to: Date.current - 1.year - 1, type: "absence")
    assert_not too_old.valid?
    # 今日と取り違えないよう、年つきで出す（スプリント9の指摘）
    assert_match "開始日は2025年11月24日(月)以降の日付にしてください", too_old.errors.full_messages.first

    too_far = build(from: Date.current + 1.year, to: Date.current + 1.year + 1)
    assert_not too_far.valid?
    assert_match "終了日は2027年11月24日(水)までの日付にしてください", too_far.errors.full_messages.first
  end

  test "有給休暇は土日だけの期間を申請できない（日数が0日になる）。特別休暇・欠勤は申請できる" do
    weekend = build(from: d(28), to: d(29))
    assert_not weekend.submit
    assert_equal [ "有給休暇は休日（土日・祝日）を日数に数えないため、休日だけの期間は申請できません（日数が0日になります）" ],
                 weekend.errors.full_messages

    assert_not build(from: d(28), to: d(28), part: "morning").valid?
    assert build(from: d(28), to: d(29), type: "absence").valid?
  end

  # ---- 日数（F10 で有給の残日数から引く日数） ----

  test "日数は土日を除いて数え、半休は0.5日" do
    assert_equal 3, build(from: d(26), to: d(30)).chargeable_days # 木・金・月
    assert_equal 2, build(from: d(26), to: d(27)).chargeable_days
    assert_equal Rational(1, 2), build(part: "morning").chargeable_days
    assert_equal 0, build(from: d(28), to: d(29), type: "absence").chargeable_days
    assert build(from: d(26), to: d(30)).includes_day_off?
    assert_not build(from: d(26), to: d(27)).includes_day_off?
    # 月度の範囲（11/21〜12/20 など）にかかる分だけ数える
    leave = build(from: d(26), to: d(30))
    assert_equal 2, leave.chargeable_days_within(d(21)..d(27))
  end

  # ---- 祝日（休日）を除いた日数 ----

  test "日数は祝日も除いて数える：11/20(金)〜11/24(火)の全日は、11/21(土)・11/22(日)・11/23(勤労感謝の日)を除いて2日" do
    leave = build(from: d(20), to: d(24))
    assert_equal 2, leave.chargeable_days
    assert_equal [ d(20), d(24) ], leave.working_dates
    assert_equal [ d(21), d(22), d(23) ], leave.days_off_in_period
    assert leave.includes_day_off?
    assert leave.valid?, leave.errors.full_messages.inspect

    # 祝日1日だけ（平日の祝日）も日数は0日
    assert_equal 0, build(from: d(23), to: d(23), type: "special").chargeable_days
    assert_not build(from: d(23), to: d(23), type: "special").paid_without_working_day?
  end

  test "日数は年をまたいでも祝日を除く：12/31(木)〜1/4(月)は、元日・1/2(土)・1/3(日)を除いて2日" do
    leave = build(from: d(31, month: 12), to: Date.new(2027, 1, 4))
    assert_equal 2, leave.chargeable_days
    assert_equal [ d(31, month: 12), Date.new(2027, 1, 4) ], leave.working_dates
    # 月度（12/21〜1/20）にかかる分だけ数える
    assert_equal 1, leave.chargeable_days_within(Date.new(2027, 1, 1)..Date.new(2027, 1, 31))
  end

  test "半休を祝日に指定した有給休暇は0日になるため申請できない" do
    holiday_half = build(from: d(23), to: d(23), part: "afternoon")
    assert_equal 0, holiday_half.chargeable_days
    assert_not holiday_half.submit
    assert_includes holiday_half.errors.full_messages.first, "休日だけの期間は申請できません"
  end

  test "有給休暇は休日（土日・祝日）だけの期間を申請できない（例：11/21(土)〜11/23(勤労感謝の日)）。特別休暇・欠勤はできる" do
    days_off = build(from: d(21), to: d(23))
    assert_not days_off.submit
    assert_equal [ "有給休暇は休日（土日・祝日）を日数に数えないため、休日だけの期間は申請できません（日数が0日になります）" ],
                 days_off.errors.full_messages
    assert_equal 0, LeaveRequest.count

    # 1日でも平日を含めば有給でも申請できる
    assert build(from: d(23), to: d(24)).valid?
    assert build(from: d(21), to: d(23), type: "special").submit
  end

  test "承認する直前にも、休日だけの有給休暇でないかを確かめ直す（祝日の判定を入れる前に申請された休暇など）" do
    leave = build(from: d(23), to: d(23))
    leave.save!(validate: false)

    assert_equal [ "期間がすべて休日（土日・祝日）のため、有給休暇の日数が0日になり承認できません" ], leave.approval_blockers
    assert_empty build(from: d(23), to: d(23), type: "absence").approval_blockers
  end

  # ---- 期間の重なり ----

  test "承認待ちの休暇と期間が重なる申請はできない" do
    submit!(from: d(26), to: d(27))
    leave = build(from: d(27), to: d(30), type: "special")

    assert_not leave.submit
    assert_equal [ "11/26(木)〜11/27(金) の有給休暇（全日）（承認待ち）と期間が重なっています。重なる休暇を取り下げるか、取消申請してから申請してください" ],
                 leave.errors.full_messages
  end

  test "承認済みの休暇と期間が重なる申請はできない。全日と半休、午前と午後でも同じ日なら重なる" do
    approve!(submit!(from: d(26), to: d(26), part: "morning"))

    assert_not build(from: d(26), to: d(26), part: "afternoon").valid?
    assert_not build(from: d(25), to: d(27)).valid?
    assert build(from: d(27), to: d(27)).valid?
    assert build(from: d(25), to: d(25)).valid?
  end

  test "却下・取り下げ・取り消された休暇とは重なっても申請できる" do
    rejected = submit!(from: d(26), to: d(26))
    rejected.update_columns(status: "rejected")
    withdrawn = submit!(from: d(27), to: d(27))
    assert withdrawn.withdraw
    cancelled = approve!(submit!(from: d(30), to: d(30)))
    cancelled.update_columns(cancelled_at: NOW)

    assert submit!(from: d(26), to: d(30)).pending?
  end

  test "他の人の休暇とは重なっても申請できる" do
    submit!(user: @admin, from: d(26), to: d(27))

    assert submit!(from: d(26), to: d(27)).pending?
  end

  test "同じ開始日の承認待ちが同時に作られた（一意制約に当たった）場合はエラーとして false を返す" do
    leave = build(from: d(26), to: d(26))
    leave.stub(:save, -> { raise ActiveRecord::RecordNotUnique, "UNIQUE constraint failed" }) do
      assert_not leave.submit
    end
    assert_equal [ "同じ時期の休暇の申請が同時に送られたため、申請できませんでした。休暇の一覧を確認してください" ], leave.errors.full_messages
  end

  test "ロック競合で保存できない場合は、例外にせずエラーとして false を返す" do
    leave = build
    busy = ActiveRecord::StatementInvalid.new("database is locked")
    busy.define_singleton_method(:cause) { SQLite3::BusyException.new("database is locked") }
    leave.stub(:save, -> { raise busy }) do
      assert_not leave.submit
    end
    assert_match "他の操作と同時に送信されたため", leave.errors.full_messages.first
  end

  # ---- 承認の直前の確かめ直し ----

  test "承認する直前に、承認済みの他の休暇と重なっていれば承認できない理由を返す" do
    leave = submit!(from: d(26), to: d(27))
    assert_equal [], leave.approval_blockers

    # 申請時の確かめを通り抜けた重なり（データの不整合や、取消の取り消しなど）を想定して直接作る
    other = submit!(from: d(30), to: d(30))
    other.update_columns(target_date: d(27), end_date: d(27), status: "approved")

    assert_equal [ "承認済みの 11/27(金) の有給休暇（全日） と期間が重なるため承認できません" ], leave.approval_blockers
  end

  # ---- 取消申請を出せるか ----

  test "取消申請は、承認済みで開始日が明日以降の休暇だけ出せる" do
    pending = submit!(from: d(26), to: d(26))
    assert_equal :not_approved, pending.cancellation_blocker

    future = approve!(pending)
    assert future.cancellable?

    tomorrow = approve!(submit!(from: d(25), to: d(25)))
    assert tomorrow.cancellable?, "明日の休暇は取消申請できる"

    today = approve!(submit!(from: d(24), to: d(24)))
    assert_equal :already_started, today.cancellation_blocker, "当日の休暇は取消申請できない"

    started = approve!(submit!(from: d(20), to: d(20)))
    assert_equal :already_started, started.cancellation_blocker, "過去の休暇は取消申請できない"

    future.update_columns(cancelled_at: NOW)
    assert_equal :already_cancelled, future.cancellation_blocker
  end
end
