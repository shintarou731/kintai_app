require "test_helper"

# 締めと、修正・承認・打刻が同時に届いても整合が崩れず、例外（画面では 500）にならないことを、
# 実際に別々のスレッド（別々の DB 接続）から送って確かめる。
# テストごとのトランザクションを使うと他のスレッドが書き込めないため、このクラスだけ無効にし、作った行は teardown で消す。
class MonthlyClosingConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    # 前月（終わった月度）を締める。時計は止めない（スレッドをまたいで動かすため）
    previous = Date.current.prev_month
    @year = previous.year
    @month = previous.month
    @date = previous.change(day: 15)
  end

  teardown { cleanup! }

  def cleanup!
    # 通知（F16）は退勤・承認などで作られるので、先に消す（ユーザーなどへの外部キーがあるため）
    Notification.delete_all
    OvertimeAlert.delete_all
    MonthlyClosingEntry.delete_all
    MonthlyClosing.delete_all
    AttendanceEdit.delete_all
    AttendanceCorrectionBreak.delete_all
    ApprovalRequest.delete_all
    AttendanceBreak.delete_all
    Attendance.delete_all
    ActiveRecord::Base.connection.clear_query_cache
  end

  def run_concurrently(blocks)
    gate = Queue.new
    threads = blocks.map do |block|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          [ block.call, nil ]
        rescue StandardError => error
          [ nil, error ]
        end
      end
    end
    blocks.size.times { gate << true }
    results = threads.map(&:value)
    # テストのスレッドのクエリキャッシュに、他のスレッドが書き込む前の結果が残らないようにする
    ActiveRecord::Base.connection.clear_query_cache
    results
  end

  def close_block
    lambda do
      MonthlyClosing.close!(year: @year, month: @month, by: @admin)
      :closed
    rescue MonthlyClosing::Error => error
      error.message
    end
  end

  def errors_of(results)
    results.filter_map(&:last).map { |error| "#{error.class}: #{error.message}" }
  end

  # 締めた値（保存した日別の値）と、今の勤怠記録が一致しているか
  def assert_snapshot_matches_records
    closing = MonthlyClosing.active.sole
    entry = closing.entries.find_by!(user: @employee)
    saved = Array(entry.snapshot["days"]).find { |data| data["date"] == @date.iso8601 }
    attendance = Attendance.find_by(user: @employee, work_date: @date)
    if attendance
      assert saved, "締めた値に #{@date} の勤怠が無い"
      expected_clock_out = attendance.clock_out_at&.iso8601
      expected_clock_out.nil? ? assert_nil(saved.dig("attendance", "clock_out_at")) : assert_equal(expected_clock_out, saved.dig("attendance", "clock_out_at"))
      assert_equal attendance.worked_minutes, saved["worked"] if attendance.clocked_out?
    else
      assert_nil saved&.dig("attendance")
    end
  end

  test "2人の管理者が同時に締めても、締めは1件だけで、他は例外にならずにエラーを返す" do
    results = run_concurrently(Array.new(4) { close_block })
    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == :closed }
    assert_equal 1, MonthlyClosing.active.count
    assert_equal 1, MonthlyClosingEntry.where(user: @employee).count
  end

  test "締めと打刻修正申請の承認が同時に届いても、承認された記録と締めた値が食い違わない" do
    3.times do
      cleanup!
      request = @employee.attendance_correction_requests.new(target_date: @date, clock_in_time: "09:00", clock_out_time: "18:00",
                                                             reason: "同時操作の確認")
      assert request.submit
      approvals = Array.new(2) do
        review = ApprovalReview.new(approval_request: ApprovalRequest.find(request.id), reviewer: @admin, decision: "approve")
        -> { review.save || review.errors.full_messages.join }
      end
      results = run_concurrently([ close_block, *approvals ])

      assert_equal [], errors_of(results)
      assert_equal 1, MonthlyClosing.active.count
      if request.reload.approved?
        assert Attendance.exists?(user: @employee, work_date: @date)
      else
        assert results.any? { |result, _| result.to_s.include?("締め済みの月度") }
        assert_not Attendance.exists?(user: @employee, work_date: @date)
      end
      assert_snapshot_matches_records
    end
  end

  test "締めと管理者の直接修正が同時に届いても、締めた後の記録は変わらない" do
    3.times do
      cleanup!
      Attendance.create!(user: @employee, work_date: @date, clock_in_at: @date.in_time_zone.change(hour: 9))
      edits = Array.new(2) do |index|
        form = AttendanceRecordEditor.new(user: @employee, work_date: @date, editor: @admin).prefill
        form.clock_out_time = "18:0#{index}"
        form.reason = "退勤を入れる"
        -> { form.save || form.errors.full_messages.join }
      end
      results = run_concurrently([ close_block, *edits ])

      assert_equal [], errors_of(results)
      assert_equal 1, MonthlyClosing.active.count
      assert_operator results.count { |result, _| result == true }, :<=, 1, "同じ画面から2回保存しても1回だけ（2回目は記録が変わったエラー）"
      assert_equal results.count { |result, _| result == true }, AttendanceEdit.count
      assert_snapshot_matches_records
    end
  end
end
