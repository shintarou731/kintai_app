require "test_helper"

# 同時に届いた申請・承認・取り下げを、実際に別々のスレッド（別々の DB 接続）から送って確かめる。
# テストごとのトランザクションを使うと、他のスレッドが書き込めないため、このクラスだけ無効にし、
# 作った行は teardown で消す（テスト用 DB だけ。フィクスチャのユーザーは残す）。
class ApprovalConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 6

  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    @date = Date.current - 3
  end

  teardown do
    AttendanceCorrectionBreak.delete_all
    ApprovalRequest.delete_all
    AttendanceBreak.delete_all
    Attendance.delete_all
  end

  def build_correction(user: @employee)
    user.attendance_correction_requests.new(target_date: @date, clock_in_time: "09:00", clock_out_time: "18:00",
                                            reason: "同時送信の確認",
                                            break_inputs: { "0" => { start_time: "12:00", end_time: "13:00" } })
  end

  # blocks を同時に走らせ、[結果, 例外] の配列を返す
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
    threads.map(&:value)
  end

  test "同じ日の修正申請を同時に送っても、1件だけ作られ、他はエラーにならずに false を返す" do
    results = run_concurrently(Array.new(THREADS) { -> { build_correction.submit } })

    assert_equal [], results.filter_map(&:last).map { |error| "#{error.class}: #{error.message}" }
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal 1, ApprovalRequest.where(user: @employee, target_date: @date).count
    assert_equal 1, AttendanceCorrectionBreak.count
  end

  test "同じ申請を同時に承認しても、承認されるのは1回だけで、勤怠も1件だけ" do
    request = build_correction
    assert request.submit
    reviews = Array.new(THREADS) { ApprovalReview.new(approval_request: ApprovalRequest.find(request.id), reviewer: @admin, decision: "approve") }
    results = run_concurrently(reviews.map { |review| -> { review.save } })

    assert_equal [], results.filter_map(&:last).map { |error| "#{error.class}: #{error.message}" }
    assert_equal 1, results.count { |result, _| result == true }
    reviews.reject { |review| review.errors.empty? }.each do |review|
      assert_match "処理済みです（承認済み）", review.errors.full_messages.first
    end
    assert request.reload.approved?
    attendance = Attendance.find_by!(user: @employee, work_date: @date)
    assert_equal 1, attendance.breaks.count
  end

  test "承認と取り下げが同時に届いても、どちらか一方だけが成功し、勤怠記録と状態が食い違わない" do
    3.times do
      request = build_correction
      assert request.submit
      approvals = Array.new(THREADS / 2) do
        review = ApprovalReview.new(approval_request: ApprovalRequest.find(request.id), reviewer: @admin, decision: "approve")
        -> { review.save }
      end
      withdrawals = Array.new(THREADS / 2) do
        stale = ApprovalRequest.find(request.id)
        -> { stale.withdraw }
      end
      results = run_concurrently(approvals.zip(withdrawals).flatten)

      assert_equal [], results.filter_map(&:last).map { |error| "#{error.class}: #{error.message}" }
      assert_equal 1, results.count { |result, _| result == true }
      request.reload
      attendance = Attendance.find_by(user: @employee, work_date: @date)
      if request.approved?
        assert attendance, "承認されたなら勤怠がある"
      else
        assert request.withdrawn?
        assert_nil attendance, "取り下げられたなら勤怠は作られない"
      end

      # 次の回のために片付ける
      AttendanceBreak.delete_all
      Attendance.delete_all
    end
  end
end
