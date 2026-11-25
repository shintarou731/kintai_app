# データベースのロック競合（同時に届いた書き込みがロックを取れなかった）を表す例外の判定。
# `rescue DatabaseLockError` や `rescue_from DatabaseLockError` で使う（=== で判定する）。
# - SQLite：SQLite3::BusyException（database is locked）を原因とする ActiveRecord::StatementInvalid
# - PostgreSQL・MySQL など：ロック待ちのタイムアウト・デッドロック
module DatabaseLockError
  MESSAGE = "他の操作と同時に処理されたため、完了できませんでした。画面を再読み込みして最新の状態を確認し、もう一度お試しください。".freeze

  def self.===(error)
    case error
    when ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked
      true
    when ActiveRecord::StatementInvalid
      defined?(SQLite3::BusyException) ? error.cause.is_a?(SQLite3::BusyException) : false
    else
      false
    end
  end
end
