require "test_helper"
require "minitest/mock"

# config/initializers/sqlite_lock_wait.rb：Rails の非公開メソッドを上書きする部分の安全策と、実際に効いていること
class SqliteLockWaitTest < ActiveSupport::TestCase
  # 上書き対象のメソッドを持つ／持たない、アダプタの代わりのクラス
  def fake_adapter(with_method: true)
    Class.new do
      if with_method
        private

        def configure_connection; end
      end
    end
  end

  test "Rails 7.2 の SQLite アダプタには上書きが入っている" do
    assert_operator ActiveRecord::ConnectionAdapters::SQLite3Adapter, :<, SqliteLockWait::Patch
    assert SqliteLockWait.applicable?(ActiveRecord::ConnectionAdapters::SQLite3Adapter)
  end

  test "上書きするメソッドが無ければ、何もせず警告を出す（起動は止めない）" do
    adapter = fake_adapter(with_method: false)
    logger = StringIO.new

    assert_not SqliteLockWait.install(adapter, rails_version: Gem::Version.new("7.2.4"), logger: Logger.new(logger))
    assert_not_operator adapter, :<, SqliteLockWait::Patch
    assert_match "見つからないため", logger.string
  end

  test "Rails 8.0 以上では、アダプタ自身が同じ設定をするので上書きしない" do
    adapter = fake_adapter
    logger = StringIO.new

    assert_not SqliteLockWait.install(adapter, rails_version: Gem::Version.new("8.0.0"), logger: Logger.new(logger))
    assert_not_operator adapter, :<, SqliteLockWait::Patch
    assert_equal "", logger.string
  end

  test "メソッドがあれば上書きを入れ、2回呼んでも二重には入れない" do
    adapter = fake_adapter

    assert SqliteLockWait.install(adapter, rails_version: Gem::Version.new("7.2.4"), logger: nil)
    assert SqliteLockWait.install(adapter, rails_version: Gem::Version.new("7.2.4"), logger: nil)
    assert_equal 1, adapter.ancestors.count(SqliteLockWait::Patch)
  end

  test "接続を作ると、SQLite の接続に busy_handler_timeout が database.yml の timeout で設定される" do
    calls = []
    spy = Module.new do
      define_method(:busy_handler_timeout=) do |value|
        calls << value
        super(value)
      end
    end
    config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(timeout: 1234)
    connection = ActiveRecord::ConnectionAdapters::SQLite3Adapter.new(config)
    # 接続を開く前に、この接続の SQLite3::Database だけを見張る
    SQLite3::Database.stub(:new, ->(*args, **kwargs) { SQLite3::Database.allocate.tap { |db| db.extend(spy).send(:initialize, *args, **kwargs) } }) do
      connection.connect!
    end

    assert_equal [ 1234 ], calls
  ensure
    connection&.disconnect!
  end
end
