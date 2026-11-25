require "test_helper"
require "minitest/mock"

# SQLite のロック待ち（Rails 8 の SQLite アダプタの標準の仕組み）。
# Rails 7.2 のときは config/initializers/sqlite_lock_wait.rb で補っていたが、Rails 8 で標準になったため削除した。
# 同時に届いた申請・承認などを失敗させないために頼っている次の3点が、Rails の更新で失われていないことを確かめる。
# - database.yml の timeout が busy_handler_timeout（待つ間に Ruby の他のスレッドを動かす方式）で設定される
# - 書き込みのトランザクションは BEGIN IMMEDIATE で始まる（読み取りの後で書き込みに移るときの BusyException を防ぐ）
# - 他の接続が書き込みロックを持っていても、待っている間に他のスレッドが進み、解放されたら書き込める
class SqliteLockWaitTest < ActiveSupport::TestCase
  # テストごとのトランザクションが書き込みロックを持つと、別の接続が書き込めないため無効にする（このテストは行を書かない）
  self.use_transactional_tests = false

  def new_connection(**overrides)
    config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(overrides)
    ActiveRecord::ConnectionAdapters::SQLite3Adapter.new(config)
  end

  test "接続を作ると、database.yml の timeout が busy_handler_timeout で設定され、busy_timeout は使わない" do
    calls = []
    spy = Module.new do
      define_method(:busy_handler_timeout=) do |value|
        calls << [ :busy_handler_timeout, value ]
        super(value)
      end

      define_method(:busy_timeout=) do |value|
        calls << [ :busy_timeout, value ]
        super(value)
      end
    end
    connection = new_connection(timeout: 1234)
    # 接続を開く前に、この接続の SQLite3::Database だけを見張る
    SQLite3::Database.stub(:new, ->(*args, **kwargs) { SQLite3::Database.allocate.tap { |db| db.extend(spy).send(:initialize, *args, **kwargs) } }) do
      connection.connect!
    end

    assert_equal [ [ :busy_handler_timeout, 1234 ] ], calls
  ensure
    connection&.disconnect!
  end

  test "database.yml のロック待ちの上限は 5000 ミリ秒" do
    assert_equal 5000, ActiveRecord::Base.connection_db_config.configuration_hash[:timeout]
  end

  test "トランザクションは BEGIN IMMEDIATE で始まる" do
    connection = new_connection
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] if payload[:connection].equal?(connection) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      connection.transaction { connection.select_value("SELECT 1") }
    end

    assert_includes statements.map(&:upcase), "BEGIN IMMEDIATE TRANSACTION"
  ensure
    connection&.disconnect!
  end

  test "他の接続が書き込みロックを持っている間も他のスレッドは進み、ロックが解放されたら待っていた接続が書き込める" do
    holder = new_connection
    waiter = new_connection(timeout: 5000)
    holder.begin_db_transaction # BEGIN IMMEDIATE で書き込みロックを持ったままにする

    waiting = Thread.new do
      waiter.transaction { waiter.select_value("SELECT 1") }
      :written
    rescue ActiveRecord::StatementInvalid => error
      error
    end

    # 待っている間も、このスレッドは止まらずに進む（方式そのものは1つ目のテストで確かめる）
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    10.times { sleep 0.05 }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert waiting.alive?, "ロックが解放される前に、待っている接続が終わってしまった"

    holder.commit_db_transaction

    assert_equal :written, waiting.value
    assert_operator elapsed, :<, 2.5
  ensure
    waiting&.join(10)
    holder&.disconnect!
    waiter&.disconnect!
  end
end
