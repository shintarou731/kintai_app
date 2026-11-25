# スプリント 18 実装レポート：Rails のバージョンアップ（保守作業）

対象：Rails 7.2.4 → **8.1.4.1**（Rails 8 系の最新の安定版。rubygems でのリリース日は **2026-11-04**（UTC 02:47、JST 同日 11:47））。
Ruby は 3.4.9 のまま（Rails 8.1.4.1 の要件は Ruby >= 3.2.0。3.4.9 で起動・全テストを確認）。アプリ本体（`app/`）は変更していない。

**結論：単体テスト・同時実行テスト・rubocop・brakeman・開発サーバーの確認は完了した。`bin/rails test:system` の3回連続の実行は、メモリ不足で Claude Code に止められたため未完了（下記「未完了の項目」）。**

## 実装内容

### 1. 開発用 DB のバックアップ
- `tmp/backup/development-before-sprint-18.sqlite3` に `VACUUM INTO` で取った（WAL の中身も含む）。`PRAGMA integrity_check` は ok。
- 件数は元の DB と一致（`tmp/backup/counts-before.txt` / `counts-backup.txt`）。

### 2. gem
`Gemfile` の変更は2行だけ。`bundle update rails --conservative` で、Rails 系以外を動かさずに解決した。

| gem | 前 | 後 | 理由 |
|---|---|---|---|
| rails ほか Rails 本体（actioncable・actionmailbox・actionmailer・actionpack・actiontext・actionview・activejob・activemodel・activerecord・activestorage・activesupport・railties） | 7.2.4 | 8.1.4.1 | 今回の目的 |
| action_text-trix | なし | 2.1.19 | actiontext 8.1 の新しい依存（自動で追加） |
| uri | 標準添付 | 1.1.2 | Rails 8.1 の新しい依存（自動で追加） |
| benchmark・cgi | 0.5.0・0.5.2 | 削除 | Rails 8.1 が依存しなくなった（自動で削除） |

- `Gemfile` の制約：`rails "~> 8.1.4", ">= 8.1.4.1"`。`sqlite3` を `">= 1.4"` → `">= 2.1"`（activerecord 8.1 の要件 `gem "sqlite3", ">= 2.1"` に合わせた。ロックの版は 2.10.2 のまま）。
- **上げなかった gem**（すでに Rails 8.1 に対応している版だった）：sqlite3 2.10.2、importmap-rails 2.2.3、turbo-rails 2.0.23、stimulus-rails 1.3.4、sprockets-rails 3.5.2、puma 8.1.2、jbuilder 2.15.1。いずれも最新、または依存の上限がなく Rails 8.1 で解決できた。
- web-console 4.2.1 は 4.3.0 があるが、4.2.1 も Rails 8.1 で動き（開発サーバーで確認、警告なし）、必要ではないので据え置いた。
- `Gemfile.lock` の CHECKSUMS：110件すべてに sha256 が入っている（空の行は0件）。

### 3. `bin/rails app:update` の差分
リポジトリのコピー（`tmp/` の中。確認後に削除）で全部を上書きして差分を出し、本体には1つずつ判断して手で取り込んだ。

**取り込んだもの**
| ファイル | 内容 |
|---|---|
| `config/environments/development.rb` | `Cache-Control` → `cache-control`（Rack 3 の小文字のヘッダー。動作は同じ）、`config.action_dispatch.verbose_redirect_logs = true`（ログだけ） |
| `config/environments/test.rb` | `cache-control` の小文字化（コメントも） |
| `config/environments/production.rb` | `config.silence_healthcheck_path = "/up"`（`/up` のログを出さない。ルートは既存） |
| `config/initializers/filter_parameter_logging.rb` | `:cvv, :cvc` を追加（ログのマスクを増やすだけ。該当する列はない） |
| `config/initializers/content_security_policy.rb` | コメントの追加だけ |
| `config/puma.rb` | コメントの修正だけ |
| `bin/rubocop` | コメントの修正だけ |

**取り込まなかったもの（理由）**
| 差分 | 理由 |
|---|---|
| `config/application.rb` の `time_zone`・ja ロケールの削除 | アプリの設定なので残した |
| development の `cache_store` を常に `:memory_store` にする | ログインの回数制限（`rate_limit`）が開発環境で働き始め、動作が変わるため |
| development の `query_log_tags_enabled = true` | 一度取り込んだが外した。有効にすると prepared statements が無効になり、開発ログの SQL にメールアドレスなどの値がそのまま出た（`[FILTERED]` にならない）。SQL の実行方法も変わるため |
| development の `assets.quiet`、disallowed deprecation の設定の削除 | sprockets を使い続けるため／既存の設定を消さない |
| test の `perform_caching = false`・mailer の host（`www.example.com` → `example.com`）・`require` の削除 | 既存の設定を変える必要がない |
| production の `force_ssl` をコメントにする | セキュリティが下がるため残した |
| production の logger の置き換え（`TaggedLogging.logger(STDOUT)`） | ログの書式（時刻・レベル）が変わるため |
| production の `assets.compile = false` の削除、`public_file_server` の1年キャッシュ | sprockets のまま／動作が変わるため |
| `config/initializers/assets.rb` | sprockets 用のコメントが消えるだけで、Propshaft 向けのひな形のため |
| `puma.rb` の `plugin :solid_queue` | Solid Queue を使っていない |
| `bin/setup`・`bin/dev`・`bin/ci`・`config/ci.rb` | 開発の道具の変更・新機能で、今回の目的に不要 |
| `public/*.html`・`public/400.html`・`icon.png`・`icon.svg` | エラーページとアイコンの見た目が変わるため |
| Active Storage のマイグレーション3件（`active_storage:update`） | このアプリは Active Storage を使っておらず、テーブルもない（流すと失敗する） |

### 4. 新しい既定値（`config.load_defaults 7.2` → `8.1`）
app:update が出すのは `new_framework_defaults_8_1.rb` だけなので、8.0 の分（Rails の `load_defaults "8.0"` の中身）も合わせて、**1項目ずつだけ有効にした状態で `bin/rails test` を流した**（8回。一時ファイルの initializer で切り替え、確認後に削除）。

| # | 項目 | 結果 | 影響の確認 |
|---|---|---|---|
| 1 | 8.0 `action_dispatch.strict_freshness = true` | 783件 成功 | `fresh_when`・`stale?` などの条件付き GET を使っていない |
| 2 | 8.0 `Regexp.timeout = 1` | 783件 成功 | アプリの正規表現は短い入力の単純なものだけ |
| 3 | 8.1 `action_controller.escape_json_responses = false` | 783件 成功 | `render json:` を使っていない |
| 4 | 8.1 `active_support.escape_js_separators_in_json = false` | 783件 成功 | `to_json` は data 属性（HTML でエスケープされる）と修正画面のハッシュ用だけ |
| 5 | 8.1 `active_record.raise_on_missing_required_finder_order_columns = true` | 783件 成功 | 全テーブルに主キーがある |
| 6 | 8.1 `action_controller.action_on_path_relative_redirect = :raise` | 783件 成功 | リダイレクト先は `*_path`、`request.fullpath`、`/` 始まりに検証済みの通知のパスだけ |
| 7 | 8.1 `action_view.render_tracker = :ruby` | 783件 成功 | キャッシュのダイジェストの計算方法だけ |
| 8 | 8.1 `action_view.remove_hidden_field_autocomplete = true` | 783件 成功 | hidden の input から `autocomplete="off"` が無くなる。テストで確かめている箇所はなく、見た目は変わらない |

- 8.1 で入る `yjit = !Rails.env.local?` は本番だけで YJIT を有効にする（開発・テストは変わらない）。
- そのうえで `config.load_defaults 8.1` に上げ、`new_framework_defaults_8_*.rb` は残していない。上げられなかった項目はない。
- 起動後の値を確認した：`loaded_config_version=8.1`、`strict_freshness=true`、`Regexp.timeout=1.0`、`time_zone=Tokyo`、`default_locale=ja`。

### 5. 削除した initializer と、直した API
- **削除**：`config/initializers/sqlite_lock_wait.rb` と、その専用テスト `test/initializers/sqlite_lock_wait_test.rb`（空になったフォルダも）。
  - Rails 8.1.4.1 の `SQLite3Adapter#configure_connection` が、`database.yml` の `timeout` を `@raw_connection.busy_handler_timeout=` に渡す（initializer と同じ方式）ことをソースで確認した。
  - Rails 8.1 は普通のトランザクションを常に `BEGIN immediate TRANSACTION` で始め（`begin_db_transaction`）、接続にも `default_transaction_mode: :immediate` を必ず渡す。
- **置き換えのテスト**：`test/integration/sqlite_lock_wait_test.rb`（4件）
  - 接続を作ると `busy_handler_timeout=` が timeout の値で1回だけ呼ばれ、`busy_timeout=` は呼ばれない
  - `database.yml` の timeout が 5000
  - トランザクションが `BEGIN IMMEDIATE TRANSACTION` で始まる
  - 別の接続が書き込みロックを持っている間も他のスレッドが進み、ロックが解放されると、待っていた接続が書き込める
  - 注：一時スクリプトで試したところ、sqlite3 gem 2.x では従来の `busy_timeout` でも他のスレッドは止まらなかった。そのため4つ目のテストでは方式の違いは分からない。方式の確認は1つ目のテストで行っている。
- **`default_transaction_mode: immediate`（database.yml）**：Rails 8.1 では、この設定が無くても同じ動きになる（冗長）。ただ、意図をはっきりさせるために残し、コメントで「Rails 8 はこの設定が無くても IMMEDIATE で始める」と書き足した。
- **`DatabaseLockError`**：Rails 8 は `SQLite3::BusyException` を `ActiveRecord::StatementTimeout`（`StatementInvalid` の子クラス）に変換する。`cause` は BusyException のままなので、今の判定のままで動く。変更していない。
- **直した API**：なし。Rails 8.0/8.1 で削除・非推奨になった API（enum のキーワード引数、`Rails.application.secrets`、`ActiveSupport::Configurable`、`mb_chars`、`ActiveSupport::Deprecation.warn` など）を検索したが、使っていなかった。テストの deprecation の警告は **0件**。
- **そのまま残したもの**
  - `test/application_system_test_case.rb` の Chrome 用のパッチ：Capybara は 3.40.0 のまま（最新）で、`Storage.clearDataForOrigin` を `origin: "*"` で呼ぶ処理も変わっていない。Rails とは関係なく、まだ必要。
  - `config/initializers/development_clock.rb`（DEV_NOW）：`DEV_NOW="2026-11-23 21:59:30"` で起動すると `Time.current` がその時刻になることを確認した。`ActiveRecord.validate_migration_timestamps` も 8.1 にある。
  - `csv` gem（3.3.2）：変更なし。Rails 8.1 は csv に依存しないので、Gemfile に書いておく必要がある。
  - システムテストの共通のヘルパー（`log_in_as`・`log_out`）：変更なし。
- sprockets-rails（3.5.2）のまま。開発サーバーで CSS・JS（importmap の application・turbo・stimulus）が 200 で返ることを確認した。
- 認証は今の自作の仕組みのまま。ログインの回数制限（`rate_limit`、Rails 8.1 で中のキャッシュのキーが変わった）は、一時テスト（リポジトリには入れていない）で `cache_store` をメモリに差し替えて確かめた。11回目で「ログインの試行回数が多すぎます。…」に移る。

## 受け入れ基準の自己チェック（保守作業の完了条件）
- [x] Rails 8 系の最新の安定版（8.1.4.1）。rubygems の API で確認し、prerelease は除いた。
- [x] Ruby 3.4.9 のまま動く。
- [x] `bin/rails db:migrate:status`：14件すべて up。
- [x] 開発用 DB の件数は前後で同じ（17テーブル。`diff tmp/backup/counts-before.txt tmp/backup/counts-after.txt` の差分なし。integrity_check ok）。
- [x] `db/schema.rb` は変更なし。Rails 8.1 で `tmp/` に書き出して比べると、違いは先頭の `ActiveRecord::Schema[7.2]` → `[8.1]` だけ（テーブルの定義は同じ）。マイグレーションを流していないので書き換えていない。次にマイグレーションを追加したときに `[8.1]` になる。
- [x] `bin/rails test`：783件、失敗0・エラー0、deprecation 0（最終の状態で再実行）。
- [x] 同時実行のテストを単体で5回ずつ：6ファイルと `sqlite_lock_wait_test`、すべて5回とも失敗0・エラー0。
- [ ] **`bin/rails test:system` 3回連続：未完了**。1回目の途中（11件成功、失敗0の時点）で、メモリ不足のため Claude Code が止めた。指示に従い、自分では再実行していない。残っていたテストのプロセス（ruby・chromedriver・Chrome）は自分で止めた。
- [x] `bin/rubocop`：237ファイル、指摘0。
- [x] `bin/brakeman`：警告 4件 → 3件。Rails 7.2 のサポート終了（EOLRails）の警告は消えた（残りは下記）。
- [x] 開発サーバー（`bin/rails server -p 3000`）：`/login` 200、ログイン後のホーム `/` 200（「ログインしました。」が出る）、`/up` 200。確認後に停止した（3000番で待ち受けているプロセスがないことも確認）。

## 自己評価（各 1〜10）
| 基準 | 点 | 根拠 |
|---|---|---|
| 機能性 | 7 | 単体・同時実行・開発サーバーは問題なし。システムテスト（画面操作）の3回連続は未確認のため、満点にはしない |
| プロダクトの深さ | 7 | 既定値を1項目ずつテストで確かめ、取り込まなかった差分の理由も示した。`query_log_tags` の副作用も見つけて外した |
| UI/UX デザイン | 7 | 見た目に関わる差分（エラーページ・アイコン）は取り込んでいない。`autocomplete` の削除は hidden の input だけ。画面での確認はシステムテストに頼るので未確認 |
| コード品質 | 8 | Rails の非公開メソッドの上書きを削除し、標準の仕組みを確かめるテストに置き換えた。rubocop の指摘0 |

## 動作確認の方法
- 起動：`bin/rails server -p 3000`
- ログイン：`http://localhost:3000/login`。開発用 DB の `jiro@example.com` / `password123`（管理者）でログインできた。
  - 注：`admin@example.com`・`hanako@example.com` は `password123` ではログインできなかった（422）。以前の評価でパスワードが変わったと思われる。DB は変えていない。
- ホーム：`http://localhost:3000/`
- 確認：`bin/rails test`、`bin/rails test:system`（同時に流さない）、同時実行のテスト（`bin/rails test test/models/<名前>_concurrency_test.rb`、`bin/rails test test/integration/sqlite_lock_wait_test.rb`）

## 実行したテストと結果
| コマンド | 結果 |
|---|---|
| `bin/rails test`（load_defaults 7.2 のまま、initializer の削除前） | 784件中 失敗1（initializer のテストの「Rails 7.2 の上書きが入っている」。8.x では入らないので当然）、エラー1（sprockets のキャッシュの `Permission denied`、下記） |
| `bin/rails test`（既定値を1項目ずつ × 8回） | すべて 783件、失敗0・エラー0、deprecation 0 |
| `bin/rails test`（load_defaults 8.1、最終の状態） | 783件、9643 assertions、失敗0・エラー0・skip0、deprecation 0（2回） |
| 同時実行のテスト × 5回ずつ | approval 3件・leave 6件・paid_leave 9件・shift 5件・overtime_alert 2件・monthly_closing 3件・sqlite_lock_wait 4件。35回すべて失敗0・エラー0 |
| `bin/rails test:system` | **未完了**（メモリ不足で止められた） |
| `bin/rubocop` | 237ファイル、指摘0 |
| `bin/brakeman` | 警告3件（終了コード3。修正前も警告4件で3。`brakeman.ignore` はない） |

brakeman の比較：
| 警告 | 前 | 後 |
|---|---|---|
| EOLRails：Support for Rails 7.2.4 ended on 2026-08-09 | あり | **なし** |
| Ruby2Shell：Ruby 3.4.9 の CVE-2026-132825（3.4.13 以上へ） | あり | あり（Ruby は変えない指示のため） |
| Mass Assignment：`admin/employees_controller.rb:76` の `:role` | あり | あり（既存。管理者だけの画面） |
| Mass Assignment：`admin/employees_controller.rb:80` の `:role` | あり | あり（既存） |

## 未完了の項目
- **`bin/rails test:system` の3回連続の実行**。メモリ不足で止められた。メモリに余裕があるときに、オーケストレーターまたはエバリュエーターが実行する必要がある。実行用のスクリプトは `tmp/sprint18/system.sh`（3回続けて流し、`tmp/sprint18/system-summary.txt` に結果を書く）。単体テストと同時に流さないこと。

## 既知の問題・懸念
- **sprockets のキャッシュの `Permission denied @ rb_file_s_rename`（Windows）**：Rails を上げてアセットのキャッシュが作り直されたため、最初のテストで1件、開発サーバーの最初の `/login` で1回（500）出た。どちらも、もう一度実行すると出なかった。Sprint 1 で記録したものと同じ、キャッシュが空のときの Windows のファイルロックの競合。コードの問題ではないと判断したが、評価の最初の1回で出る可能性はある。
- `database.yml` の `default_transaction_mode: immediate` は、Rails 8.1 では冗長（あってもなくても同じ）。意図を示すために残した。
- `remove_hidden_field_autocomplete`：古い Firefox では、戻るボタンで hidden の値（CSRF のトークンなど）が復元されることがある、というのが以前の `autocomplete="off"` の理由だった。Rails は不要と判断して既定値を変えた。このアプリで問題が出る場面は見つけていない。
- `params.require(...).permit(...)` は Rails 8 で `params.expect` が推奨になったが、非推奨の警告は出ないので変えていない（エラーのときの応答が変わりうるため）。
- 開発用 DB の `admin@example.com` のパスワードが `password123` ではない（以前からの状態と思われる。今回は変えていない）。

## エバリュエーターが確かめるべき点（リスクの高い順）
1. **`bin/rails test:system` を3回続けて流し、3回とも失敗0・エラー0か**（今回は未確認。Rails 8.1 での Turbo・importmap・sprockets の画面の動作が、ここで初めて全部確かめられる）。
2. **同時に操作したときのロック待ち**（initializer を削除した部分）：同時実行のテストを単体で流す。可能なら、画面で承認などを同時に送り、「他の操作と同時に…」のメッセージや 500 が出ないか。
3. **フォームの送信**（`remove_hidden_field_autocomplete`、`action_on_path_relative_redirect = :raise`）：ログイン・ログアウト（`button_to`）・申請・承認・CSV のダウンロード・通知から画面への移動（リダイレクト）が、今までどおり動くか。
4. **開発環境の DEV_NOW**：`DEV_NOW="2026-11-23 21:59:30" bin/rails server -p 3000` で、画面上部の注意書きと打刻の時刻。
5. **見た目**：CSS・JS が読み込まれ、レイアウトが変わっていないか（sprockets のまま）。最初の表示で `Permission denied` が出たら再読み込みで直るか。
6. `bin/rails db:migrate:status` がすべて up で、`db/schema.rb` に差分がないこと。
