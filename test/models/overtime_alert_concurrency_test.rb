require "test_helper"

# 残業の警告（F16）を、実際に別々のスレッド（別々の DB 接続）から同時に判定しても、80%・100% の通知が1回ずつになること。
# テストごとのトランザクションを使うと他のスレッドが書き込めないため、このクラスだけ無効にし、作った行は teardown で消す。
class OvertimeAlertConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 6

  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    @today = Date.current
    setting = WorkRuleSetting.current
    setting.overtime_warning_hours = 10
    setting.save!
  end

  teardown do
    Notification.delete_all
    OvertimeAlert.delete_all
    AttendanceBreak.delete_all
    Attendance.delete_all
    WorkRuleSetting.delete_all
  end

  # 今月度の中の日に、休憩なしで「所定 8:00 ＋ 残業 overtime 分」の勤怠を作る
  def overtime!(overtime)
    period = WorkRules.current.period_containing(@today)
    date = period.start_date
    start = Time.zone.local(date.year, date.month, date.day, 9)
    Attendance.create!(user: @employee, work_date: date, clock_in_at: start, clock_out_at: start + 8.hours + overtime.minutes)
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
    threads.map(&:value)
  end

  test "同じ従業員の判定が同時に走っても、80%と100%の警告と通知は1回ずつ" do
    overtime!(700) # 80%（8:00）と 100%（10:00）の両方を超えている
    results = run_concurrently(Array.new(THREADS) { -> { OvertimeAlert.check(@employee, date: @today) } })

    assert_equal [], results.filter_map(&:last).map { |error| "#{error.class}: #{error.message}" }
    assert_equal [ 80, 100 ], results.flat_map(&:first).map(&:level).sort, "警告を作れたのは、段階ごとに1つの判定だけ"
    assert_equal [ 80, 100 ], OvertimeAlert.where(user: @employee).order(:level).pluck(:level)
    assert_equal 2, Notification.where(recipient: @employee, kind: "overtime_alert").count
    assert_equal 2, Notification.where(recipient: @admin, kind: "overtime_alert").count
  end

  test "1人分の判定と全員の判定（勤務ルールの変更）が同時に走っても、二重にならない" do
    overtime!(500)
    blocks = Array.new(THREADS) do |index|
      index.even? ? -> { OvertimeAlert.check(@employee, date: @today) } : -> { OvertimeAlert.check_all(date: @today) }
    end
    results = run_concurrently(blocks)

    assert_equal [], results.filter_map(&:last).map { |error| "#{error.class}: #{error.message}" }
    assert_equal [ 80 ], OvertimeAlert.where(user: @employee).pluck(:level)
    assert_equal 1, Notification.where(recipient: @employee, kind: "overtime_alert").count
    assert_equal 1, Notification.where(recipient: @admin, kind: "overtime_alert").count
  end
end
