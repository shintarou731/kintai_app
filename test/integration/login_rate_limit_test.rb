require "test_helper"
require "minitest/mock"

# ログインの回数制限（SessionsController の rate_limit：同じ IP アドレスから 3分で10回まで）。
#
# テスト環境の cache_store は null_store なので、そのままでは回数が数えられず、回数制限は働かない。
# rate_limit は store: を指定しないと、クラスを読み込んだ時点の cache_store のオブジェクトを使い続ける
# （後から cache_store を入れ替えても反映されない）。そこで、そのオブジェクトの increment だけを、
# テストの間だけメモリのストアに転送する。Minitest の stub はブロックを抜けると元に戻す。
class LoginRateLimitTest < ActionDispatch::IntegrationTest
  LIMIT = 10
  WINDOW = 3.minutes
  RATE_LIMIT_MESSAGE = "ログインの試行回数が多すぎます。しばらく待ってから再度お試しください。".freeze
  LOGIN_ERROR_MESSAGE = "メールアドレスまたはパスワードが正しくありません。".freeze
  OTHER_IP = "203.0.113.25".freeze

  test "10回までは回数制限で止められず、成否は通常どおり判定される" do
    with_memory_rate_limit_store do
      (LIMIT - 1).times { |i| assert_login_failed_normally(attempt: i + 1) }

      # 10回目は正しいパスワードなら通常どおりログインできる
      sign_in_as users(:admin)
      assert_redirected_to root_path
      assert_equal users(:admin).id, session[:user_id]
    end
  end

  test "11回目は回数制限で止められ、ログイン画面へ戻されてメッセージが出る" do
    with_memory_rate_limit_store do
      LIMIT.times { |i| assert_login_failed_normally(attempt: i + 1) }

      sign_in_as users(:admin), password: "wrong-password"
      assert_blocked_by_rate_limit
    end
  end

  test "回数制限で止められている間は、正しいパスワードでもログインできない" do
    with_memory_rate_limit_store do
      LIMIT.times { assert_login_failed_normally }

      2.times do
        sign_in_as users(:admin)
        assert_blocked_by_rate_limit
      end

      # ログイン画面の表示（create 以外）は回数制限の対象ではない
      get login_path
      assert_response :success
    end
  end

  test "制限時間が過ぎると制限が解け、再びログインを試せる" do
    with_memory_rate_limit_store do
      LIMIT.times { assert_login_failed_normally }
      sign_in_as users(:admin)
      assert_blocked_by_rate_limit

      # 3分の期間が終わる直前はまだ止められる
      travel WINDOW - 5.seconds
      sign_in_as users(:admin)
      assert_blocked_by_rate_limit

      travel 10.seconds
      sign_in_as users(:admin), password: "wrong-password"
      assert_response :unprocessable_entity
      assert_select ".flash--alert", LOGIN_ERROR_MESSAGE

      sign_in_as users(:admin)
      assert_redirected_to root_path
      assert_equal users(:admin).id, session[:user_id]
    end
  end

  test "回数は IP アドレスごとに数え、別の IP アドレスからは止められない" do
    with_memory_rate_limit_store do
      LIMIT.times { assert_login_failed_normally }
      sign_in_as users(:admin)
      assert_blocked_by_rate_limit

      # 別の IP アドレスからは、10回まで通常どおり判定される
      (LIMIT - 1).times do
        post login_path, params: { email: users(:admin).email, password: "wrong-password" }, env: { "REMOTE_ADDR" => OTHER_IP }
        assert_response :unprocessable_entity
      end
      post login_path, params: { email: users(:admin).email, password: "password123" }, env: { "REMOTE_ADDR" => OTHER_IP }
      assert_redirected_to root_path
      assert_equal users(:admin).id, session[:user_id]
    end
  end

  test "メモリのストアへの差し替えはテストの中だけで、終わると元のストアに戻る" do
    store = SessionsController.cache_store
    with_memory_rate_limit_store do
      assert_equal 1, store.increment("rate-limit-check", 1, expires_in: WINDOW)
    end

    assert_instance_of ActiveSupport::Cache::NullStore, store
    assert_nil store.increment("rate-limit-check", 1, expires_in: WINDOW)
  end

  private

  def with_memory_rate_limit_store(&block)
    memory_store = ActiveSupport::Cache::MemoryStore.new
    SessionsController.cache_store.stub(:increment, ->(*args, **options) { memory_store.increment(*args, **options) }, &block)
  end

  def assert_login_failed_normally(attempt: nil)
    sign_in_as users(:admin), password: "wrong-password"
    assert_response :unprocessable_entity, "#{attempt}回目の失敗が回数制限で止められた"
    assert_select ".flash--alert", LOGIN_ERROR_MESSAGE
    assert_nil session[:user_id]
  end

  def assert_blocked_by_rate_limit
    assert_redirected_to login_path
    assert_equal RATE_LIMIT_MESSAGE, flash[:alert]
    assert_nil session[:user_id]

    follow_redirect!
    assert_response :success
    assert_select ".flash--alert", RATE_LIMIT_MESSAGE
  end
end
