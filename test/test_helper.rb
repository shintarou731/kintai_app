ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # スレッド並列だと SQLite の1つのテスト DB を複数スレッドのトランザクションが奪い合い、
    # "cannot start a transaction within a transaction" などで失敗するため、既定は直列で実行する。
    # （Windows ではプロセス並列が使えない。並列にしたい場合は PARALLEL_WORKERS を指定する）
    parallelize(workers: ENV.fetch("PARALLEL_WORKERS", 1).to_i, with: :threads)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

module SignInHelper
  # fixtures の users は全員パスワード "password123"
  def sign_in_as(user, password: "password123")
    post login_path, params: { email: user.email, password: password }
  end
end

class ActionDispatch::IntegrationTest
  include SignInHelper
end
