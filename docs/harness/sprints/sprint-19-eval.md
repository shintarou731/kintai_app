# スプリント 19 評価：ログインの回数制限のテストの追加

## 判定：合格

追加された `test/integration/login_rate_limit_test.rb`（6件）は、今の `rate_limit to: 10, within: 3.minutes, only: :create`（IP ごと）を、境界も含めて正しく確かめている。回数・期間・数える単位・対象アクションを一時的に変える7通りの変異（下記）は、どれも該当するテストが失敗して見つかった。seed を変えた単体3回・全体2回・システムテスト1回・rubocop は、すべて問題なし。差し替えは `stub` で、例外やアサーション失敗のときも元に戻ることを確かめた。重大なバグはない。軽微な懸念が2件ある（時間の境界に実時間の余裕を使っていること、スレッド並列のときの影響）。

## 採点
| 基準 | 点 | 閾値 | 判定 | 根拠 |
|---|---|---|---|---|
| 機能性 | 9 | 8 | 合格 | 求められた5項目をすべて確かめている。`rate_limit` を無効にすると4件、`to: 11` で4件、`to: 9` で5件、`within: 2.minutes` と `within: 4.minutes` でそれぞれ1件、`by:` を固定値やメールアドレスにすると1件、`only:` に `new` を足すと4件が失敗した（境界と単位がテストで押さえられている）。seed を変えた単体3回・全体2回・システムテスト1回は、どれも失敗0。3分の直前の判定は、実時間の経過を5秒の余裕でまかなっている（軽微） |
| プロダクトの深さ | 8 | 6 | 合格 | **前回（sprint-18）の値を引き継いだ。** 今回はテストだけの追加で、アプリの動作と画面に変化がないため |
| UI/UX デザイン | 8 | 6 | 合格 | **前回（sprint-18）の値を引き継いだ。** 理由は上と同じ。止められたときの画面の文言（`.flash--alert`）がテストで固定されたのは良い点 |
| コード品質 | 8 | 7 | 合格 | アプリのコードを変えずに、`rate_limit` が `store` をラムダに閉じ込める仕組み（Rails 8.1.4.1 の `rate_limiting.rb`）に合わせた差し替えを選び、理由をファイル先頭に書いている。ヘルパー（`assert_login_failed_normally`・`assert_blocked_by_rate_limit`）で重複が少ない。`sleep` を使わず `travel`。rubocop 指摘0。並列時の影響を避ける仕組みが無い点と、時刻を固定していない点で減点 |

## 受け入れ基準の検証結果
- [x] **10回までは止められない** — テスト1：9回の失敗はどれも 422 と通常のエラー文言、10回目に正しいパスワードを送るとホームへ移り `session[:user_id]` が入る。`to: 9` に変えるとこのテストが23行目で失敗した（10回目が止められる）ので、10回目の境界を本当に確かめている。
- [x] **11回目に止められる（ステータス・リダイレクト先・メッセージ）** — テスト2：10回の失敗（すべて 422）の後、11回目は `assert_redirected_to login_path`（302）、`flash[:alert]` が「ログインの試行回数が多すぎます。しばらく待ってから再度お試しください。」、`follow_redirect!` 後の画面の `.flash--alert` にも同じ文言。`to: 11` に変えると33行目で失敗した（11回目が 422 になる）。
- [x] **時間が経つと解ける** — テスト4：2分55秒進めた時点ではまだ止められ、さらに10秒（3分5秒）進めると、誤ったパスワードは通常の 422、正しいパスワードはログインできる。`within: 2.minutes` では61行目（直前でもう解けている）、`within: 4.minutes` では65行目（直後でもまだ止められる）で失敗し、3分の前後の両側を押さえている。`MemoryStore#increment` は最初の書き込みの `expires_at` を引き継ぐ固定窓で、`Entry#expired?` は `Time.now` を使うため、`travel` が効くことをソースで確かめた。
- [x] **IP アドレスごとに数える** — テスト5：127.0.0.1 が止められた後でも、`REMOTE_ADDR` を 203.0.113.25 にすると9回の失敗は 422、10回目はログインできる。同じメールアドレスなので、メールアドレス単位でないことも分かる。`by: -> { "all" }`、`by: -> { params[:email].to_s }` のどちらに変えても83行目で失敗した。
- [x] **止められている間は、正しいパスワードでも入れない** — テスト3：正しいパスワードで2回続けて送っても、どちらも `/login` へ戻され `session[:user_id]` は空。ログイン画面の GET は 200（create だけが対象）。`only: %i[new create]` に変えると4件が失敗した。
- [x] **差し替えが必ず元に戻る** — Minitest 5.27.0 の `Object#stub` は `ensure` で元のメソッドに戻す（`lib/minitest/mock.rb` で確認）。`tmp/` に置いた一時テストで、ブロックの中で例外を出した場合と `flunk` した場合の両方で、抜けた後は `increment` が `nil`（NullStore の元の動き）に戻ることを確かめた（2 runs・成功の確認部分は通過。一時テストは削除済み）。なお特異クラスには元の `increment` の別名が残るが、これは Minitest の通常の動きで、振る舞いは元どおり。テスト6も同じことを確かめている。
- [x] **ほかのテストに影響しない（直列実行のとき）** — メモリのストアはテストごとに新しく作られ、テストの間で回数が持ち越されない。`bin/rails test` を seed 1111 と 54321 で流し、どちらも 789 runs・失敗0。アプリの中で `Rails.cache` / `increment` を使っている箇所は `rate_limit` 以外に無い（grep で確認）。
- [x] **テストが本当に効いている** — `rate_limit` の2行をコメントにすると 6 runs・4 failures（11回目・正しいパスワード・時間・IP の4件）。残りの2件は回数制限が無くても成り立つ内容なので、失敗しないのは正しい。毎回 `tmp/sprint19/` のバックアップから戻し、`git diff main -- app/` が0行であることを確かめた（計8回）。

### generator が挙げた懸念への所見
1. **`Rails.cache` と同じオブジェクトであること** — `RAILS_ENV=test bin/rails runner` で、`before_action` のラムダに閉じ込められた `store`・`SessionsController.cache_store`・`ApplicationController.cache_store`・`Rails.cache` が、すべて同じ `NullStore`（同じ object_id）であることを確かめた。`stub` の間は `Rails.cache.increment` もメモリのストアに向くが、アプリで `increment` を使っているのは `rate_limit` だけなので、直列実行では実害はない。
2. **`PARALLEL_WORKERS` を2以上にしたとき** — 懸念は正しい。`stub` は共有オブジェクトの特異メソッドを書き換えるので、ほかのスレッドで同時に流れているログインのテストも、同じキー（`rate-limit:sessions:127.0.0.1`）で同じメモリのストアに数えられる。その結果、このテストの「10回までは止められない」が早く止められて失敗したり、ほかのテストのログインが 302 で止められたりしうる。ただし `test/test_helper.rb` のとおり、このリポジトリは SQLite のためスレッド並列では元々安定しない前提で、既定は1。今は実害なし（軽微）。
3. **Rails の内部の前提に依存していること** — 依存しているのは「`store:` の既定値が読み込み時の `cache_store` であること」と「`increment` だけを使うこと」。前提が崩れた場合は、回数が数えられなくなる方向に倒れるので、テストは「11回目で止められない」として**失敗する**（見逃して通ることはない）。今回 `rate_limit` を無効にした変異で、この方向の失敗が実際に起きることを確かめた。安全側に倒れているので、受け入れられる。

### もっと頑丈な方法の提案（任意）
- **今の方法のまま、自分のスレッドだけ転送する**：stub のラムダで、作ったスレッド以外からの呼び出しは元の `increment` に渡す。統合テストのリクエストは同じスレッドで処理されるので、これで並列実行の懸念 2 がなくなる。アプリのコードは変えずに済む。
  ```ruby
  owner = Thread.current
  original = SessionsController.cache_store.method(:increment)
  forward = ->(*args, **options) { Thread.current.equal?(owner) ? memory_store.increment(*args, **options) : original.call(*args, **options) }
  ```
- **アプリ側で `store:` を指定する**：たとえば `rate_limit ..., store: RATE_LIMIT_STORE` として、`Rails.cache` とは別の専用のオブジェクトにする。こうすると懸念 1（`Rails.cache` との共有）と懸念 3（既定値の前提）がなくなり、差し替えの対象が「回数制限だけが使うオブジェクト」とはっきりする。ただし、テスト環境で常に数えるストア（memory_store）にすると、ほかのテストのログインも 127.0.0.1 で数えられて止められうるので、テスト環境では null のままにして、このテストだけで差し替える形は変わらない。アプリのコードの変更になるので、必要ならオーケストレーター経由で判断する。

## バグ（重要度順）
重大・中のバグはない。
1. **[軽微]** 「3分の直前はまだ止められる」の判定が、実時間の経過に依存している
   - 再現手順：テスト4で、回数の窓は1回目のリクエストの実時刻から始まるが、`travel WINDOW - 5.seconds` は「11回のリクエストを終えた後の今」から2分55秒進める。
   - 期待される動作：機械の速さによらず、窓の始まりから2分55秒の時点を確かめる。
   - 実際の動作：11回のリクエストに今は約1秒（単体実行で1件あたり約2秒・リクエスト約90ミリ秒）かかるので、実際には「窓の始まりから2分56秒ほど」を見ている。重い環境で11回に5秒以上かかると、この行が誤って失敗する。今回の6回の実行ではすべて成功。
2. **[軽微]** スレッド並列（`PARALLEL_WORKERS` 2以上）にすると、ほかのテストのログインもこのテストのメモリのストアで数えられる（上の所見 2）。既定の直列では起きない。

## 改善点（ジェネレーターへの具体的な指示）
いずれも必須ではない（今回の合否には影響しない）。
- `test "制限時間が過ぎると..."` の最初（`with_memory_rate_limit_store do` の直後）に `freeze_time` を入れ、窓の始まりと `travel` の起点を同じ時刻にする。これで2分55秒・3分5秒がそのままの意味になり、機械の速さに左右されない。
- `with_memory_rate_limit_store` の stub のラムダを、上の「自分のスレッドだけ転送する」形にして、並列実行でもほかのテストに影響しないようにする。
- ファイル先頭のコメントに、「`SessionsController.cache_store` は `Rails.cache` と同じオブジェクトで、stub の間は `Rails.cache.increment` も転送される」ことを1行足す。

## テスト実行結果
- 追加したテストの単体実行（`bin/rails test test/integration/login_rate_limit_test.rb`）
  - `--seed 101`：6 runs, 207 assertions, 0 failures, 0 errors, 0 skips（13.3秒）
  - `--seed 2026`：6 runs, 207 assertions, 0 failures, 0 errors, 0 skips（12.8秒）
  - `--seed 98765`：6 runs, 207 assertions, 0 failures, 0 errors, 0 skips（12.5秒）
- `bin/rails test`
  - `--seed 1111`：789 runs, 9850 assertions, 0 failures, 0 errors, 0 skips（119.8秒、deprecation 0件）
  - `--seed 54321`：789 runs, 9850 assertions, 0 failures, 0 errors, 0 skips（121.8秒、deprecation 0件）
- `bin/rails test:system`（`bin/rails test` の後に、同時ではなく実行）：62 runs, 1923 assertions, 0 failures, 0 errors, 0 skips（184.4秒）
- `bin/rubocop`：238 files inspected, no offenses detected
- 変異テスト（`--seed 4242`、毎回元に戻した）
  | 変更 | 結果 | 失敗したテスト |
  |---|---|---|
  | `rate_limit` の2行をコメント | 4 failures | 11回目・正しいパスワード・時間・IP |
  | `to: 11` | 4 failures | 同上 |
  | `to: 9` | 5 failures | 10回まで・11回目・正しいパスワード・時間・IP |
  | `within: 2.minutes` | 1 failure | 時間（61行目：直前で解けている） |
  | `within: 4.minutes` | 1 failure | 時間（65行目：直後でも止まる） |
  | `by: -> { "all" }` | 1 failure | IP（83行目） |
  | `by: -> { params[:email].to_s }` | 1 failure | IP（83行目） |
  | `only: %i[new create]` | 4 failures | 11回目・正しいパスワード・時間・IP |
- 後片付け
  - `app/controllers/sessions_controller.rb` は毎回バックアップから戻し、最後に `git diff main -- app/` が空であることを確かめた。`git status` の新しいファイルは `sprint-19-report.md`・`login_rate_limit_test.rb`・この評価レポートだけ。
  - 開発サーバーは起動していない。開発用 DB には触れていない（`bin/rails runner` は `RAILS_ENV=test` で読み取りだけ）。
  - 一時ファイル（`tmp/sprint19/`）は削除した。ruby・chromedriver のプロセスは残っていない。
