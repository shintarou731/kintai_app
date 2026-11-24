# SQLite のロック待ちを、Ruby のスレッドを止めずに行う（Rails 8 の SQLite アダプタと同じ方式）。
#
# Rails 7.2 は database.yml の timeout を SQLite の busy_timeout に渡すが、これは待っている間
# Ruby の GVL（同時に1つのスレッドしか Ruby を実行できない仕組み）を握ったまま眠るため、
# Puma の別スレッドがロックを持っていると、そのスレッドも進めずに timeout まで待ってから失敗する。
# sqlite3 gem の busy_handler_timeout= は、待つ間に sleep して他のスレッドを動かす。
#
# Rails の非公開メソッド（SQLite3Adapter#configure_connection）を上書きするため、次の場合は何もしない。
# - Rails 8.0 以上（アダプタ自身が同じ設定をするので不要。Rails を上げたらこのファイルは削除する）
# - 上書きするメソッドが無い（Rails の更新で名前が変わった）。警告をログに出し、従来の busy_timeout のまま動かす
module SqliteLockWait
  TARGET_METHOD = :configure_connection

  # 上書きを入れてよいか（adapter_class は ActiveRecord::ConnectionAdapters::SQLite3Adapter）
  def self.applicable?(adapter_class, rails_version: Rails.gem_version)
    return false if rails_version >= Gem::Version.new("8.0")

    adapter_class.private_method_defined?(TARGET_METHOD) || adapter_class.method_defined?(TARGET_METHOD)
  end

  # 条件を満たせば上書きを入れる。入れたら true
  def self.install(adapter_class, rails_version: Rails.gem_version, logger: Rails.logger)
    unless applicable?(adapter_class, rails_version: rails_version)
      if rails_version < Gem::Version.new("8.0")
        logger&.warn("[SqliteLockWait] #{adapter_class}##{TARGET_METHOD} が見つからないため、ロック待ちの設定を変えずに動かします")
      end
      return false
    end

    adapter_class.prepend(Patch) unless adapter_class < Patch
    true
  end

  module Patch
    private

    def configure_connection
      super
      timeout = @config[:timeout]
      return unless timeout && !@config[:retries] && @raw_connection.respond_to?(:busy_handler_timeout=)

      @raw_connection.busy_handler_timeout = self.class.type_cast_config_to_integer(timeout)
    end
  end
end

ActiveSupport.on_load(:active_record_sqlite3adapter) do
  SqliteLockWait.install(self)
end
