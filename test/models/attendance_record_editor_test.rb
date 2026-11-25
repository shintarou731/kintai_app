require "test_helper"

# 管理者による勤怠の直接修正（F14）：直す・作る・削除する。理由が必須。履歴（誰が・いつ・修正前・修正後・理由）を残す
class AttendanceRecordEditorTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.zone.local(2026, 11, 25, 10, 0)
  DATE = Date.new(2026, 11, 20)

  setup do
    travel_to NOW
    @admin = users(:admin)
    @employee = users(:employee)
  end

  teardown { travel_back }

  def at(hour, minute = 0, date: DATE)
    Time.zone.local(date.year, date.month, date.day, hour, minute)
  end

  def editor(**attributes)
    AttendanceRecordEditor.new(user: @employee, work_date: DATE, editor: @admin, **attributes)
  end

  test "退勤漏れの勤怠に退勤と休憩を入れて直すと、記録が変わり、修正前・修正後・理由の履歴が残る" do
    attendance = Attendance.create!(user: @employee, work_date: DATE, clock_in_at: at(9))
    form = editor.prefill
    assert_equal "09:00", form.clock_in_time
    form.clock_out_time = "18:00"
    form.break_inputs = { "0" => { start_time: "12:00", start_day: "0", end_time: "13:00", end_day: "0" } }
    form.reason = "タイムカードで 18:00 の退勤を確認"
    assert form.save, form.errors.full_messages.inspect

    attendance.reload
    assert_equal at(18), attendance.clock_out_at
    assert_equal [ [ at(12), at(13) ] ], attendance.breaks.map { |item| [ item.started_at, item.ended_at ] }
    edit = AttendanceEdit.sole
    assert_equal [ "updated", @admin, @employee, DATE, "タイムカードで 18:00 の退勤を確認" ], [ edit.operation, edit.editor, edit.user, edit.work_date, edit.reason ]
    assert_nil edit.before_attendance.clock_out_at
    assert_equal at(18), edit.after_attendance.clock_out_at
    assert_equal 480, edit.after_attendance.worked_minutes
    assert_equal NOW, edit.created_at
  end

  test "勤怠が無い日は新しく作る（日付をまたぐ退勤も入れられる）" do
    form = editor(clock_in_time: "22:00", clock_out_time: "02:00", clock_out_day: "1", reason: "打刻忘れ")
    assert form.save, form.errors.full_messages.inspect
    attendance = Attendance.find_by!(user: @employee, work_date: DATE)
    assert_equal at(2, date: DATE + 1), attendance.clock_out_at
    assert_equal "created", AttendanceEdit.sole.operation
    assert_nil AttendanceEdit.sole.before_record
  end

  test "削除すると勤怠が消え、削除前の記録と理由が履歴に残る" do
    attendance = Attendance.create!(user: @employee, work_date: DATE, clock_in_at: at(9), clock_out_at: at(9, 1))
    attendance.breaks.create!(started_at: at(9), ended_at: at(9, 1))
    form = editor(reason: "誤って打刻した", record_token: AttendanceRecordEditor.token_for(attendance))
    assert form.destroy_record, form.errors.full_messages.inspect
    assert_not Attendance.exists?(attendance.id)
    edit = AttendanceEdit.sole
    assert_equal "deleted", edit.operation
    assert_equal at(9), edit.before_attendance.clock_in_at
    assert_nil edit.after_record
  end

  test "理由は必須。矛盾した時刻は打刻修正申請と同じ規則で拒否し、記録も履歴も変わらない" do
    Attendance.create!(user: @employee, work_date: DATE, clock_in_at: at(9), clock_out_at: at(18))
    blank = editor.prefill
    blank.clock_out_time = "19:00"
    blank.reason = "  "
    assert_not blank.save
    assert_includes blank.errors.full_messages, "理由を入力してください"

    reversed = editor.prefill
    reversed.clock_out_time = "08:00"
    reversed.reason = "直す"
    assert_not reversed.save
    assert_match "退勤時刻は出勤時刻より後にしてください", reversed.errors.full_messages.join

    future = editor.prefill.tap { |form| form.reason = "x" }
    future.instance_variable_set(:@work_date, NOW.to_date + 1)
    assert_not future.save
    assert_match "未来の日付", future.errors.full_messages.join

    unchanged = editor.prefill.tap { |form| form.reason = "同じ" }
    assert_not unchanged.save
    assert_match "今の記録と同じ内容です", unchanged.errors.full_messages.join

    blank_delete = editor(reason: "")
    assert_not blank_delete.destroy_record
    assert_equal at(18), Attendance.sole.clock_out_at
    assert_equal 0, AttendanceEdit.count
  end

  test "画面を開いた後に記録が変わっていたら（本人の打刻など）、上書きしない" do
    attendance = Attendance.create!(user: @employee, work_date: DATE, clock_in_at: at(9))
    form = editor.prefill
    attendance.update!(clock_out_at: at(17))
    form.clock_out_time = "18:00"
    form.reason = "退勤を入れる"
    assert_not form.save
    assert_match "画面を開いた後に、この日の記録が変わりました", form.errors.full_messages.join
    assert_equal at(17), attendance.reload.clock_out_at
  end

  test "有効な管理者が2人以上なら自分の勤怠は直せない（1人なら直せる）" do
    Attendance.create!(user: @admin, work_date: DATE, clock_in_at: at(9))
    own = AttendanceRecordEditor.new(user: @admin, work_date: DATE, editor: @admin).prefill
    own.clock_out_time = "18:00"
    own.reason = "自分の打刻忘れ"
    assert own.blockers.empty?
    assert own.save

    User.create!(name: "管理 次郎", email: "jiro2@example.com", password: "password123", role: "admin", hired_on: Date.new(2024, 4, 1))
    again = AttendanceRecordEditor.new(user: @admin, work_date: DATE, editor: @admin).prefill
    again.clock_out_time = "19:00"
    again.reason = "直す"
    assert_not again.save
    assert_match "ご自身の勤怠は他の管理者が直します", again.errors.full_messages.join
  end

  test "従業員は直せない" do
    form = AttendanceRecordEditor.new(user: @employee, work_date: DATE, editor: @employee, clock_in_time: "09:00",
                                      clock_out_time: "18:00", reason: "x")
    assert_not form.save
    assert_match "管理者の権限が無い", form.errors.full_messages.join
  end
end
