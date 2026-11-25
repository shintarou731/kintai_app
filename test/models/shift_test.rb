require "test_helper"

# シフト（F11）の入力の確かめ・日付をまたぐシフト・下書きと公開の状態
class ShiftTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # 2026-11-25 は水曜日
  NOW = Time.zone.local(2026, 11, 25, 10, 0)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
    @date = Date.new(2026, 11, 26)
  end

  teardown { travel_back }

  def build(start_time: "9:00", end_time: "18:00", break_minutes: "60", date: @date, user: @employee)
    Shift.new(user: user, work_date: date, start_time: start_time, end_time: end_time, break_minutes: break_minutes)
  end

  def approved_leave!(from, to = from, part: "full_day", type: "paid", user: @employee)
    leave = user.leave_requests.new(target_date: from, end_date: to, leave_type: type, day_part: part, reason: "私用のため")
    leave.save!(validate: false)
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: NOW)
    leave
  end

  test "開始・終了・休憩を入れて登録でき、時刻は分で持つ" do
    shift = build
    assert shift.save, shift.errors.full_messages.inspect
    assert_equal [ 540, 1080, 60 ], [ shift.start_minute, shift.end_minute, shift.break_minutes ]
    assert_equal "9:00〜18:00", shift.range_label
    assert_equal 480, shift.scheduled_work_minutes
    assert_not shift.overnight?
  end

  test "日付をまたぐシフト（22:00〜翌6:00）は開始した日のシフトで、終了は翌日の時刻になる" do
    shift = build(start_time: "22:00", end_time: "06:00", break_minutes: "60")
    assert shift.save, shift.errors.full_messages.inspect
    assert shift.overnight?
    assert_equal "22:00〜翌6:00", shift.range_label
    assert_equal Time.zone.local(2026, 11, 26, 22, 0), shift.starts_at
    assert_equal Time.zone.local(2026, 11, 27, 6, 0), shift.ends_at
    assert_equal 420, shift.scheduled_work_minutes
  end

  test "全角の数字・コロンも受け付ける" do
    shift = build(start_time: "９：００", end_time: "１８：３０", break_minutes: "６０")
    assert shift.valid?, shift.errors.full_messages.inspect
    assert_equal [ 540, 1110, 60 ], [ shift.start_minute, shift.end_minute, shift.break_minutes ]
  end

  test "休憩が空欄なら休憩なし（0分）" do
    shift = build(break_minutes: "")
    assert shift.valid?
    assert_equal 0, shift.break_minutes
  end

  test "終了が開始と同じなら登録できない" do
    shift = build(start_time: "9:00", end_time: "09:00")
    assert_not shift.valid?
    assert_includes shift.errors.full_messages.join, "終了時刻が開始時刻と同じです"
  end

  test "休憩が勤務時間以上なら登録できない（日付をまたぐシフトも勤務時間で比べる）" do
    shift = build(start_time: "9:00", end_time: "10:00", break_minutes: "60")
    assert_not shift.valid?
    assert_includes shift.errors.full_messages, "休憩時間は勤務時間（1:00）より短くしてください"

    overnight = build(start_time: "23:00", end_time: "1:00", break_minutes: "119")
    assert overnight.valid?, overnight.errors.full_messages.inspect
    overnight.break_minutes = "120"
    assert_not overnight.valid?
  end

  test "時刻の形が正しくない・休憩が数値でない・マイナス・小数なら、それぞれ分かるエラーになる" do
    shift = build(start_time: "25:00", end_time: "abc", break_minutes: "abc")
    assert_not shift.valid?
    messages = shift.errors.full_messages
    assert_includes messages.join, "開始時刻は「9:00」のように 時:分 で入力してください"
    assert_includes messages.join, "終了時刻は「18:00」のように 時:分 で入力してください"
    assert_includes messages, "休憩時間は数値（分）で入力してください（例：60）"

    assert_includes build(break_minutes: "-5").tap(&:valid?).errors.full_messages, "休憩時間は0分以上にしてください"
    assert_includes build(break_minutes: "1.5").tap(&:valid?).errors.full_messages, "休憩時間は分の整数で入力してください（例：60）"
    assert_includes build(start_time: "", end_time: "").tap(&:valid?).errors.full_messages, "開始時刻を入力してください"
  end

  test "同じ人・同じ日のシフトは1件だけ（DB の一意の索引でも止める）" do
    build.save!
    duplicate = build(start_time: "13:00", end_time: "22:00")
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save }
  end

  test "前日の日付をまたぐシフトと重なる時間は登録できない" do
    build(start_time: "22:00", end_time: "6:00", date: @date).save!
    overlap = build(start_time: "5:00", end_time: "14:00", date: @date + 1)
    assert_not overlap.valid?
    assert_includes overlap.errors.full_messages, "前日（11/26(木)）のシフト（22:00〜翌6:00）と時間が重なっています"
    assert build(start_time: "6:00", end_time: "15:00", date: @date + 1).valid?

    build(start_time: "5:00", end_time: "12:00", date: @date + 3).save!
    night_before = build(start_time: "22:00", end_time: "6:00", date: @date + 2)
    assert_not night_before.valid?
    assert_includes night_before.errors.full_messages, "翌日（11/29(日)）のシフト（5:00〜12:00）と時間が重なっています"
  end

  test "全日の休暇の日は、確認が無いと登録できない。半休の日は登録できる" do
    approved_leave!(@date)
    shift = build
    assert_not shift.valid?
    assert_includes shift.errors.full_messages.join, "この日は 従業 花子 さんの休暇（有給（全日））の日です"
    shift.leave_acknowledged = "1"
    assert shift.valid?, shift.errors.full_messages.inspect

    approved_leave!(@date + 1, part: "morning")
    half = build(date: @date + 1, start_time: "13:00", end_time: "18:00")
    assert half.valid?
    assert_equal [ "morning" ], half.half_day_leaves.map(&:day_part)
  end

  test "休暇の日のシフトでも、時刻を変えない保存（削除）は確認なしでできる" do
    shift = build
    shift.save!
    approved_leave!(@date)
    shift.reload
    shift.update!(published_start_minute: 540, published_end_minute: 1080, published_break_minutes: 60)
    shift.remove!(by: @admin)
    assert shift.reload.removed?
  end

  test "無効な従業員・範囲外の日付には登録できない" do
    inactive = build(user: users(:inactive_employee))
    assert_not inactive.valid?
    assert_includes inactive.errors.full_messages.join, "無効な従業員にはシフトを登録・変更できません"

    far = build(date: Date.new(2027, 11, 26))
    assert_not far.valid?
    assert_includes far.errors.full_messages.join, "日付は2025/11/25〜2027/11/25の日付にしてください"
  end

  test "状態：下書き → 公開中 → 変更・未公開 → 削除・未公開。公開中の内容は published_* で読む" do
    shift = build
    shift.save!
    assert_equal :draft, shift.state
    assert_nil shift.published_starts_at

    shift.publish_draft!(now: NOW)
    assert_equal :published, shift.reload.state
    assert_nil shift.revised_at

    shift.update!(start_time: "10:00", end_time: "19:00")
    assert_equal :changed, shift.state
    assert_equal "9:00〜18:00", shift.published_range_label
    assert_equal Time.zone.local(2026, 11, 26, 9, 0), shift.published_starts_at
    assert_equal 480, shift.published_scheduled_work_minutes

    shift.publish_draft!(now: NOW + 1.hour)
    assert_equal :published, shift.reload.state
    assert_equal NOW + 1.hour, shift.revised_at

    shift.remove!(by: @admin)
    assert_equal :removing, shift.reload.state
    assert Shift.published.exists?(shift.id), "削除予定でも、公開するまでは従業員に公開中の内容を見せる"
    assert_not Shift.live.exists?(shift.id)
  end

  test "一度も公開していないシフトは、削除するとすぐに消える" do
    shift = build
    shift.save!
    shift.remove!(by: @admin)
    assert_not Shift.exists?(shift.id)
  end

  test "古い lock_version で保存すると StaleObjectError（同時編集）" do
    shift = build
    shift.save!
    other = Shift.find(shift.id)
    other.update!(start_time: "10:00")
    shift.start_time = "11:00"
    assert_raises(ActiveRecord::StaleObjectError) { shift.save }
  end

  test "公開（publish_draft!）は lock_version を変えない（同時に開いていた編集画面から保存できる）" do
    shift = build
    shift.save!
    version = shift.lock_version
    Shift.find(shift.id).publish_draft!(now: NOW)
    assert_equal version, shift.reload.lock_version
  end
end
