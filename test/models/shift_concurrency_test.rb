require "test_helper"

# シフト作成（F11）で、2人以上の管理者が同じマス・同じ週を同時に操作しても、整合が崩れず例外にならないことを、
# 実際に別々のスレッド（別々の DB 接続）から同時に送って確かめる。テストごとのトランザクションを使うと他のスレッドが
# 書き込めないため、このクラスだけ無効にし、作った行は teardown で消す（テスト用 DB だけ。フィクスチャの行は残す）。
class ShiftConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 6

  setup do
    @admin = users(:admin)
    @employee = users(:employee)
    # 来週の月曜日（今日から1年以内）
    @week = Date.current.next_week(:monday)
    @date = @week + 2
    @early = ShiftPattern.create!(name: "同時 早番", start_time: "9:00", end_time: "18:00", break_minutes: 60)
    @late = ShiftPattern.create!(name: "同時 遅番", start_time: "13:00", end_time: "22:00", break_minutes: 60)
  end

  teardown do
    # 通知（F16）は申請・承認・公開などで作られるので、先に消す（ユーザーなどへの外部キーがあるため）
    Notification.delete_all
    OvertimeAlert.delete_all
    Shift.where(work_date: (@week - 7)..(@week + 6)).delete_all
    ShiftPublication.where(week_start: @week).delete_all
    ShiftPattern.where(id: [ @early.id, @late.id ]).delete_all
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

  test "空いたマスに6人が同時にパターンを割り当てても、シフトは1件だけで、残りは競合として知らせる" do
    assignments = Array.new(THREADS) do |index|
      ShiftAssignment.new(user: @employee, date: @date, pattern: index.even? ? @early : @late, admin: @admin, expected_lock_version: nil)
    end
    results = run_concurrently(assignments.map { |assignment| -> { assignment.save } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal 1, Shift.where(user: @employee, work_date: @date).count
    assignments.reject { |assignment| assignment.errors.empty? }.each do |assignment|
      assert_match(/同時にこのマスを変更した|他の操作と同時に処理された/, assignment.errors.full_messages.first)
    end
  end

  test "同じシフトを、同じ時点の画面から6人が同時に変更しても、保存されるのは1件だけ（後の側は StaleObjectError）" do
    shift = Shift.create!(user: @employee, work_date: @date, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    version = shift.lock_version
    starts = %w[10:00 11:00 12:00 13:00 14:00 15:00]

    results = run_concurrently(starts.map do |start|
      lambda do
        record = Shift.find(shift.id)
        record.assign_attributes(start_time: start, end_time: "23:00", lock_version: version, updated_by: @admin)
        record.save
      rescue ActiveRecord::StaleObjectError
        :stale
      end
    end)

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal THREADS - 1, results.count { |result, _| result == :stale }
    shift.reload
    assert_equal version + 1, shift.lock_version
    assert_includes starts.map { |start| Shift.parse_clock_time(start) }, shift.start_minute
  end

  test "同じ週を6人が同時に公開しても、反映と記録は1回だけ" do
    Shift.create!(user: @employee, work_date: @date, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    Shift.create!(user: @admin, work_date: @date, start_time: "13:00", end_time: "22:00", break_minutes: 60)

    publications = Array.new(THREADS) { ShiftWeekPublication.new(week_start: @week, admin: @admin) }
    results = run_concurrently(publications.map { |publication| -> { publication.save } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal 1, ShiftPublication.where(week_start: @week).count
    assert_equal 2, ShiftPublication.find_by(week_start: @week).added_count
    assert Shift.on_dates(@week..(@week + 6)).all? { |shift| shift.state == :published }
  end

  test "前週のコピーを6人が同時に送っても、シフトは二重にならない" do
    Shift.create!(user: @employee, work_date: @week - 7, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    Shift.create!(user: @employee, work_date: @week - 6, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    Shift.create!(user: @admin, work_date: @week - 7, start_time: "13:00", end_time: "22:00", break_minutes: 60)

    copies = Array.new(THREADS) { ShiftWeekCopy.new(week_start: @week, admin: @admin) }
    results = run_concurrently(copies.map { |copy| -> { copy.save } })

    assert_equal [], errors_of(results)
    assert_equal 1, results.count { |result, _| result == true }
    assert_equal 3, Shift.on_dates(@week..(@week + 6)).count
  end

  test "公開と編集が同時に届いても、編集は失われず、公開の前か後のどちらかに入る" do
    shift = Shift.create!(user: @employee, work_date: @date, start_time: "9:00", end_time: "18:00", break_minutes: 60)
    version = shift.lock_version

    results = run_concurrently([
      -> { ShiftWeekPublication.new(week_start: @week, admin: @admin).save },
      lambda do
        record = Shift.find(shift.id)
        record.assign_attributes(start_time: "10:00", lock_version: version)
        record.save
      end
    ])

    assert_equal [], errors_of(results)
    assert_equal [ true, true ], results.map(&:first)
    shift.reload
    assert_equal 600, shift.start_minute, "編集は保存されている"
    assert_includes [ :published, :changed ], shift.state
  end
end
