require "test_helper"

# 有給休暇の残日数（F10）の確かめが、同時に届いた操作で入れ違わないことを、実際に別々のスレッド（別々の DB 接続）から
# 同時に送って確かめる。テストごとのトランザクションを使うと他のスレッドが書き込めないため、このクラスだけ無効にし、
# 作った行は teardown で消す（テスト用 DB だけ。フィクスチャの行は残す）。
class PaidLeaveConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 6

  setup do
    @admin = users(:admin)
    @user = User.create!(name: "同時 有給", email: "paid-concurrency@example.com", password: "password123",
                         hired_on: Date.new(2024, 4, 1))
    # 来週の月曜日から、休日を含まない日を順に使う
    @dates = []
    day = Date.current.next_week(:monday)
    while @dates.size < 20
      @dates << day if HolidayCalendar.working_day?(day)
      day += 1
    end
  end

  teardown do
    # 通知（F16）は申請・承認・公開などで作られるので、先に消す（ユーザーなどへの外部キーがあるため）
    Notification.delete_all
    OvertimeAlert.delete_all
    ApprovalRequest.where(user_id: @user.id).where.not(leave_request_id: nil).delete_all
    ApprovalRequest.where(user_id: @user.id).delete_all
    PaidLeaveGrant.where(user_id: @user.id).delete_all
    @user.delete
  end

  def grant!(days)
    PaidLeaveGrant.create!(user: @user, granted_by: @admin, granted_on: Date.current - 30, days: days.to_s)
  end

  def build_leave(from, to = from)
    @user.leave_requests.new(target_date: from, end_date: to, leave_type: "paid", day_part: "full_day", reason: "同時送信の確認")
  end

  def balance
    PaidLeaveAccount.new(User.find(@user.id)).balance
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

  def review(leave)
    ApprovalReview.new(approval_request: ApprovalRequest.find(leave.id), reviewer: @admin, decision: "approve")
  end

  test "残日数ちょうど（3日）のとき、別々の日の1日の有給を6件同時に送ると、申請されるのは3件だけ" do
    grant!(3)
    leaves = @dates.first(THREADS).map { |date| build_leave(date) }
    results = run_concurrently(leaves.map { |leave| -> { leave.submit } })

    assert_equal [], errors_of(results)
    assert_equal 3, results.count { |result, _| result == true }
    assert_equal 3, LeaveRequest.where(user_id: @user.id).count
    leaves.reject(&:persisted?).each do |leave|
      assert_match(/残日数が足りないため申請できません|同時に送信されたため/, leave.errors.full_messages.first)
    end
    assert_equal 0, PaidLeaveAccount.new(User.find(@user.id)).requestable
  end

  test "残日数ちょうど（2日）の2日間の有給を、別々の期間で同時に送っても、申請されるのは1件だけ" do
    grant!(2)
    leaves = Array.new(THREADS) { |index| build_leave(@dates[index * 2], @dates[index * 2 + 1]) }
    # 前提の確認：どの申請も2日で、互いに重ならない
    assert(leaves.all? { |leave| leave.chargeable_days == 2 })
    results = run_concurrently(leaves.map { |leave| -> { leave.submit } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal 1, LeaveRequest.where(user_id: @user.id).count
  end

  test "同じ有給の申請を同時に何度承認しても、承認は1回だけで、残日数も1回分だけ減る" do
    grant!(5)
    leave = build_leave(@dates[0], @dates[1])
    assert leave.submit
    reviews = Array.new(THREADS) { review(leave) }
    results = run_concurrently(reviews.map { |item| -> { item.save } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert leave.reload.approved?
    assert_equal 3, balance
  end

  test "合わせると残日数を超える2件の有給を同時に承認しても、承認されるのは片方だけ" do
    grant!(2)
    first = build_leave(@dates[0], @dates[1])
    assert first.submit
    # 申請時の確かめを通り抜けた2件目（データの不整合）を想定して、確かめを飛ばして保存する
    second = build_leave(@dates[2], @dates[3])
    second.save!(validate: false)

    reviews = [ first, second ].flat_map { |leave| Array.new(THREADS / 2) { review(leave) } }
    results = run_concurrently(reviews.map { |item| -> { item.save } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal 1, LeaveRequest.effective.where(user_id: @user.id).count
    assert_equal 0, balance
    assert_equal 0, PaidLeaveAccount.new(User.find(@user.id)).shortage
    loser = reviews.find { |item| item.errors.any? && item.approval_request.pending? }
    assert_match "残日数が足りないため承認できません", loser.errors.full_messages.first
  end

  test "有給の承認と、同じ人の新しい有給の申請が同時に届いても、残日数を超えない" do
    grant!(3)
    pending = build_leave(@dates[0], @dates[1])
    assert pending.submit # 承認待ち 2日（申請できる残り 1日）

    approvals = Array.new(THREADS / 2) { review(pending) }
    # 2日の申請は、承認の前後どちらに処理されても、承認待ち／承認済みの2日と合わせて残日数を超える
    submissions = Array.new(THREADS / 2) { |index| build_leave(@dates[4 + index * 2], @dates[5 + index * 2]) }
    blocks = approvals.map { |item| -> { item.save } } + submissions.map { |leave| -> { leave.submit } }
    results = run_concurrently(blocks.shuffle)

    assert_equal [], errors_of(results)
    assert pending.reload.approved?
    assert_equal 1, approvals.count { |item| item.errors.empty? }
    assert submissions.none?(&:persisted?)
    assert_equal 1, balance
  end

  test "1日分の申請と、別の有給の承認が同時に届けば、両方とも通り、残日数は0日になる" do
    grant!(3)
    pending = build_leave(@dates[0], @dates[1])
    assert pending.submit
    submission = build_leave(@dates[5])
    results = run_concurrently([ -> { review(pending).save }, -> { submission.submit } ])

    assert_equal [], errors_of(results)
    assert_equal [ true, true ], results.map(&:first)
    assert_equal 1, balance
    assert_equal 0, PaidLeaveAccount.new(User.find(@user.id)).requestable
  end

  # 付与の削除（スプリント 16.1）
  def removal(grant, reason)
    PaidLeaveGrantRemoval.new(grant: PaidLeaveGrant.find(grant.id), admin: @admin, reason: reason)
  end

  test "同じ付与の削除を6件同時に送っても、削除されるのは1回だけで、記録は1件・500 にならない" do
    grant = grant!(5)
    removals = Array.new(THREADS) { |index| removal(grant, "同時削除 #{index}") }
    results = run_concurrently(removals.map { |item| -> { item.save } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    removals.reject { |item| item.errors.empty? }.each do |item|
      assert_match(/すでに削除されています|同時に送信されたため/, item.errors.full_messages.first)
    end
    grant.reload
    assert grant.removed?
    assert_equal removals.find { |item| item.errors.empty? }.reason, grant.removal_reason
    assert_equal 0, balance
  end

  test "付与の削除と、その付与が無いと賄えない新しい有給の申請が同時に届いても、どちらか一方だけが通る" do
    older = PaidLeaveGrant.create!(user: @user, granted_by: @admin, granted_on: Date.current - 60, days: "2")
    grant!(2)
    3.times do
      leave = build_leave(@dates[0], @dates[2]) # 3日。older を消すと残り 2日 で足りない
      results = run_concurrently([ -> { removal(older, "誤登録").save }, -> { leave.submit } ])

      assert_equal [], errors_of(results)
      assert_equal 1, results.count { |result, _| result == true }, "削除と申請の両方が通ってはいけない"
      assert_equal older.reload.removed?, !leave.persisted?
      assert_equal 0, PaidLeaveAccount.new(User.find(@user.id)).shortage
      # 次の回のために元に戻す
      LeaveRequest.where(user_id: @user.id).delete_all
      older.update_columns(removed_at: nil, removed_by_id: nil, removal_reason: nil)
    end
  end

  test "付与の削除と有給の承認が同時に届いても、整合が崩れない（承認待ちの有給は別の付与で賄える）" do
    older = PaidLeaveGrant.create!(user: @user, granted_by: @admin, granted_on: Date.current - 60, days: "1")
    grant!(1)
    pending = build_leave(@dates[0])
    assert pending.submit
    results = run_concurrently([ -> { removal(older, "誤登録").save }, -> { review(pending).save } ])

    assert_equal [], errors_of(results)
    assert_equal [ true, true ], results.map(&:first)
    assert older.reload.removed?
    assert pending.reload.approved?
    account = PaidLeaveAccount.new(User.find(@user.id))
    assert_equal 0, account.balance
    assert_equal 0, account.shortage
  end
end
