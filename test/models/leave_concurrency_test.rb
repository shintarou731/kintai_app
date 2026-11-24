require "test_helper"

# 休暇申請・取消申請を、実際に別々のスレッド（別々の DB 接続）から同時に送って、二重にならないことを確かめる。
# テストごとのトランザクションを使うと、他のスレッドが書き込めないため、このクラスだけ無効にし、
# 作った行は teardown で消す（テスト用 DB だけ。フィクスチャのユーザーは残す）。
class LeaveConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 6

  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    # 必ず平日から始まる、未来の期間（来週の月曜日〜）
    @monday = Date.current.next_week(:monday)
  end

  teardown do
    LeaveCancellationRequest.delete_all
    ApprovalRequest.delete_all
  end

  def build_leave(from:, to:, part: "full_day")
    @employee.leave_requests.new(target_date: from, end_date: to, leave_type: "paid", day_part: part, reason: "同時送信の確認")
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

  def errors_of(results)
    results.filter_map(&:last).map { |error| "#{error.class}: #{error.message}" }
  end

  test "開始日の違う、期間の重なる休暇を同時に送っても、1件だけ申請される（一意制約に頼らない）" do
    # 月〜金、水、火〜木、水〜金、月〜水、水（午前半休）… すべてが水曜日を含むので、どの2件も互いに重なる。
    # 開始日は一部ずつ違うため、「同じ開始日」の一意制約では防げない組み合わせになっている。
    ranges = [ [ 0, 4, "full_day" ], [ 2, 2, "full_day" ], [ 1, 3, "full_day" ],
               [ 2, 4, "full_day" ], [ 0, 2, "full_day" ], [ 2, 2, "morning" ] ]
    common_day = @monday + 2
    leaves = ranges.map do |from, to, part|
      build_leave(from: @monday + from, to: @monday + to, part: part)
    end
    # 前提の確認：すべての期間が共通の1日（水曜日）を含む
    assert(leaves.all? { |leave| (leave.target_date..leave.end_date).cover?(common_day) })
    results = run_concurrently(leaves.map { |leave| -> { leave.submit } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal 1, LeaveRequest.where(user: @employee).count
    leaves.reject(&:persisted?).each do |leave|
      assert_match(/期間が重なっています|同時に送られたため/, leave.errors.full_messages.first)
    end
  end

  test "同じ休暇の取消申請を同時に送っても、承認待ちの取消申請は1件だけ" do
    leave = build_leave(from: @monday, to: @monday + 1)
    assert leave.submit
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: Time.current)

    requests = Array.new(THREADS) do
      @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "同時送信の確認")
    end
    results = run_concurrently(requests.map { |request| -> { request.submit } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal 1, LeaveCancellationRequest.where(leave_request: leave).count
  end

  test "同じ取消申請を同時に承認しても、処理は1回だけで、休暇は1回だけ取り消される" do
    leave = build_leave(from: @monday, to: @monday)
    assert leave.submit
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: Time.current)
    cancel = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "予定変更")
    assert cancel.submit

    reviews = Array.new(THREADS) do
      ApprovalReview.new(approval_request: ApprovalRequest.find(cancel.id), reviewer: @admin, decision: "approve")
    end
    results = run_concurrently(reviews.map { |review| -> { review.save } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert cancel.reload.approved?
    assert leave.reload.cancelled?
  end

  test "重なる2件の休暇申請を同時に承認しても、承認されるのは片方だけ" do
    first = build_leave(from: @monday, to: @monday + 1)
    second = build_leave(from: @monday + 2, to: @monday + 2)
    assert first.submit
    assert second.submit
    # 申請時の確かめを通り抜けた重なり（データの不整合）を想定して、2件目の期間を1件目に重ねる
    second.update_columns(target_date: @monday + 1, end_date: @monday + 2)

    reviews = [ first, second ].flat_map do |leave|
      Array.new(THREADS / 2) { ApprovalReview.new(approval_request: ApprovalRequest.find(leave.id), reviewer: @admin, decision: "approve") }
    end
    results = run_concurrently(reviews.map { |review| -> { review.save } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal 1, LeaveRequest.effective.where(user: @employee).count
  end

  # ---- 管理者による直接取消（F9 の追加分） ----

  def approved_leave!(from:, to:)
    leave = build_leave(from: from, to: to)
    assert leave.submit
    leave.update_columns(status: "approved", reviewer_id: @admin.id, reviewed_at: Time.current)
    leave
  end

  def other_admin
    @other_admin ||= User.create!(name: "管理 二郎", email: "admin2-concurrency@example.com", password: "password123",
                                  role: "admin", hired_on: Date.new(2021, 4, 1))
  end

  test "同じ休暇を複数の管理者が同時に直接取り消しても、取り消されるのは1回だけ" do
    leave = approved_leave!(from: @monday, to: @monday + 1)
    admins = [ @admin, other_admin ]
    cancellations = Array.new(THREADS) do |index|
      LeaveDirectCancellation.new(leave_request: LeaveRequest.find(leave.id), admin: admins[index % 2], reason: "同時取消#{index}")
    end
    results = run_concurrently(cancellations.map { |cancellation| -> { cancellation.save } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    winner = cancellations.find { |cancellation| cancellation.errors.empty? }
    leave.reload
    assert leave.directly_cancelled?
    assert_equal winner.admin, leave.cancelled_by
    assert_equal winner.reason, leave.cancellation_reason
    cancellations.reject { |cancellation| cancellation.equal?(winner) }.each do |cancellation|
      assert_match(/すでに取り消されています|同時に処理された/, cancellation.errors.full_messages.first)
    end
  ensure
    ApprovalRequest.delete_all
    User.where(email: "admin2-concurrency@example.com").delete_all
  end

  test "直接取消と、同じ休暇の取消申請の承認が同時に届いても、どちらか1回だけ処理され、整合が崩れない" do
    leave = approved_leave!(from: @monday, to: @monday)
    request = @employee.leave_cancellation_requests.new(leave_request_id: leave.id, reason: "予定変更")
    assert request.submit

    blocks = Array.new(THREADS) do |index|
      if index.even?
        cancellation = LeaveDirectCancellation.new(leave_request: LeaveRequest.find(leave.id), admin: other_admin, reason: "直接取消")
        -> { [ :direct, cancellation.save ] }
      else
        review = ApprovalReview.new(approval_request: ApprovalRequest.find(request.id), reviewer: @admin, decision: "approve")
        -> { [ :review, review.save ] }
      end
    end
    results = run_concurrently(blocks)

    assert_equal [], errors_of(results)
    successes = results.map(&:first).select { |_, saved| saved }
    assert_equal 1, successes.size, results.inspect

    leave.reload
    request.reload
    assert leave.cancelled?
    assert request.approved?, "取消申請は承認待ちに残らない"
    assert_equal 0, ApprovalRequest.pending.count
    if successes.first.first == :direct
      assert leave.directly_cancelled?
      assert request.closed_by_direct_cancellation?
      assert_equal other_admin, request.reviewer
    else
      assert_not leave.directly_cancelled?
      assert_not request.closed_by_direct_cancellation?
      assert_equal @admin, request.reviewer
    end
  ensure
    ApprovalRequest.where.not(leave_request_id: nil).delete_all
    ApprovalRequest.delete_all
    User.where(email: "admin2-concurrency@example.com").delete_all
  end
end
