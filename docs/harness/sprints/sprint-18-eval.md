# スプリント 18 評価：Rails のバージョンアップ（7.2.4 → 8.1.4.1）

## 判定：合格

Rails 8.1.4.1 に上げた後も、F1〜F17 の機能・見た目・動作は変わっていない。generator が終えられなかった `bin/rails test:system` の3回連続の実行は、3回とも 62件・失敗0・エラー0（メモリ不足での停止なし）。単体テスト・同時実行のテスト・rubocop・brakeman・画面での確認でも、問題は見つからなかった。

## 採点
| 基準 | 点 | 閾値 | 判定 | 根拠 |
|---|---|---|---|---|
| 機能性 | 9 | 8 | 合格 | システムテスト 3回×62件、単体テスト 783件、同時実行テスト 7ファイル×3回が、すべて失敗0・エラー0。ブラウザで、ログイン・打刻・申請・却下・承認・取り下げ・休暇・CSV・通知・締めのダイアログ・422 の表示・リダイレクト・Turbo の移動・戻る操作を試し、どれも前と同じに動いた。開発ログに 500 は無い |
| プロダクトの深さ | 8 | 6 | 合格 | 既定値の8項目を1つずつテストで確かめている。取り込まなかった差分（force_ssl・エラーページ・cache_store・query_log_tags など）の理由は妥当。削除した initializer の代わりに、Rails 8 の標準の仕組みを確かめるテストを用意した |
| UI/UX デザイン | 8 | 6 | 合格 | 1280px と 375px で、CSS・JS（sprockets・importmap）が読み込まれ、レイアウトは前と同じ。13画面で横スクロールなし。祝日の赤・土曜の青・状態の色・メッセージも変わらない。エラーページとアイコンの差分は取り込んでいない |
| コード品質 | 8 | 7 | 合格 | rubocop 237ファイルで指摘0。deprecation の警告0件。Rails の非公開メソッドを上書きしていた initializer を消し、標準の動作を確かめるテストに置き換えた。差分は小さく、アプリのための設定（ja・Tokyo・database.yml）も残っている |

## 受け入れ基準の検証結果

### 保守作業の完了条件
- [x] **`bin/rails test:system` 3回連続**（`tmp/sprint18/system.sh` を使用。中身は `bin/rails test:system` を3回順に実行して結果を集計するだけで、問題が無いことを読んで確かめた）
  - 1回目：62 runs, 1923 assertions, 0 failures, 0 errors, 0 skips（188秒）
  - 2回目：62 runs, 1923 assertions, 0 failures, 0 errors, 0 skips（188秒）
  - 3回目：62 runs, 1923 assertions, 0 failures, 0 errors, 0 skips（184秒）
  - deprecation は3回とも0件。出た警告は Ruby 本体の `fiddle` の案内（Rails とは無関係）だけ。
  - メモリ不足での停止はなかった。ほかのテスト・サーバーとは同時に動かしていない。開始前の空きメモリは約 3.2GB。終了後、ruby・chromedriver・テスト用の Chrome は残っていなかった（残っていたのはユーザー自身の Chrome のプロファイルだけ）。
- [x] **`bin/rails test`**：783 runs, 9643 assertions, 0 failures, 0 errors, 0 skips。deprecation 0件。
- [x] **同時実行のテストを単体で3回ずつ**：approval（3件）・leave（6件）・monthly_closing（3件）・overtime_alert（2件）・paid_leave（9件）・shift（5件）・`sqlite_lock_wait_test`（4件）。21回すべて失敗0・エラー0。
- [x] **`bin/rubocop`**：237 files inspected, no offenses detected。
- [x] **`bin/brakeman`**：警告 4件 → 3件。比べるために、`git archive main` で main の中身を `tmp/` に出して brakeman をかけた（ブランチは切り替えていない）。
  - 消えた警告：EOLRails（Rails 7.2.4 のサポート終了）
  - 残った警告：Ruby2Shell（Ruby 3.4.9 の CVE。Ruby は今回の範囲外）、`admin/employees_controller.rb` の 76・80行目の `:role`（前からある。管理者だけの画面）
  - 新しい警告はない。
- [x] **設定の値**（`bin/rails runner` で読み取り）：Rails 8.1.4.1、`loaded_config_version=8.1`、time_zone=Tokyo、default_locale=ja、`strict_freshness=true`、`Regexp.timeout=1.0`、`action_on_path_relative_redirect=:raise`、`remove_hidden_field_autocomplete=true`、DB は `timeout: 5000`・`default_transaction_mode: immediate`。
- [x] **`db:migrate:status`**：14件すべて up、down は0件。`db/schema.rb` に差分はない。

### 設定の差分（`git diff main -- config/ Gemfile Gemfile.lock bin/rubocop`）
- [x] アプリのための設定は消えていない：`config/application.rb` の `time_zone = "Tokyo"`、`default_locale = :ja`、`available_locales = [:ja, :en]`。`database.yml` の `default_transaction_mode: immediate`・timeout はそのまま（コメントを足しただけ）。initializer は `assets.rb`・`content_security_policy.rb`（コメントだけ）・`development_clock.rb`（変更なし）・`filter_parameter_logging.rb`（`:cvv, :cvc` を足しただけ）・`inflections.rb`・`permissions_policy.rb`。
- [x] Gemfile.lock の変更は Rails 本体と、その依存（`action_text-trix`・`uri` の追加、`benchmark`・`cgi` の削除）だけ。rack 3.2.9・turbo-rails・importmap-rails・sprockets・sqlite3・puma・capybara・selenium-webdriver は変わっていない。
- [x] 取り込まなかった差分の判断は妥当。
  - `force_ssl` をコメントにしない：安全側の判断。
  - development の `cache_store` を常に `:memory_store` にしない：今の開発環境は `null_store` で、回数制限は前から働かない。変えると開発時の動きが変わる。
  - `query_log_tags_enabled`：prepared statements が無効になってログに値が出るという理由は、具体的で妥当。
  - production の logger・`public_file_server`・エラーページ・アイコン：見た目と動作が変わるので、取り込まないのが正しい。
  - Active Storage のマイグレーション：テーブルが無いので流さないのが正しい。
- [x] `load_defaults 8.1` で動作が変わったものは無かった。画面で確かめた結果は次のとおり。
  - `remove_hidden_field_autocomplete`：hidden の input に `autocomplete` が付かなくなった（修正申請のフォームで確認）。見た目と送信は変わらない。
  - `action_on_path_relative_redirect = :raise`：ログイン・ログアウト・申請・取り下げ・承認・却下・通知からの移動のリダイレクトで、エラーは出なかった。
  - 取り込んだ `verbose_redirect_logs` によって、開発ログにリダイレクト元の行（例：`↳ app/controllers/clock_ins_controller.rb:7`）が出るようになった。ログだけの変化。
- [x] **initializer の削除の代わり**：`test/integration/sqlite_lock_wait_test.rb` で、`busy_handler_timeout=` が使われ `busy_timeout=` は使われないこと、`BEGIN IMMEDIATE TRANSACTION` で始まることを確かめている（3回とも成功）。

### 画面での確認（Playwright MCP、1280px と 375px）
ログインに使ったアカウント：管理者は `jiro@example.com`／`password123`、従業員は `hanako@example.com`／`hanako2026`、`double@example.com`・`eval161@example.com`／`password123`。
- [x] **ログイン・ログアウト（F1）**
  - 未ログインで `/` を開くと `/login` に移り、「ログインしてください。」と出た。
  - パスワードを間違えると 422 で「メールアドレスまたはパスワードが正しくありません。」と出た（Turbo で同じ画面に表示）。
  - 正しく入れると `/` に移り、「ログインしました。」とヘッダーの名前が出た。
  - ヘッダーの「ログアウト」（`button_to`）で `/login` に戻り、「ログアウトしました。」と出た。
- [x] **ログインの回数制限**：開発・テスト環境はどちらも `null_store` なので、回数制限は働かない（main でも同じ。`tmp/caching-dev.txt` は無い）。そこで、`rate_limit` が使うキャッシュの `increment` だけをメモリのストアに差し替える一時テストを `tmp/` に置いて流した。10回失敗（どれも 422）した後の11回目は、正しいパスワードでも `/login` に戻され、「ログインの試行回数が多すぎます」と出た（1 run・14 assertions で成功）。一時テストは確認後に削除した。
- [x] **打刻（F3・F4）**：次郎（未出勤）で確かめた。
  - 「出勤」をダブルクリックしても POST は1回だけ。「出勤しました（08:02）」と出て、状態は「勤務中」になった。
  - 「休憩開始」で「休憩中」になり、押せるのは休憩終了だけ。「休憩終了」で「勤務中」に戻った。
  - 「退勤」で「退勤済み」になり、4つのボタンはすべて押せなくなった。
  - 退勤の後に `/clock_in` を直接 POST すると、302 でホームに戻された。ログに INSERT は無い（二重には記録されない）。
  - 時計は秒まで進んでいる。
- [x] **勤怠履歴と祝日（F5）**
  - 2026年11月：11/23 は「勤労感謝の日」で `history-row--holiday`、11/3 は「文化の日」、11/21（土）は `history-row--saturday`。
  - 上部の合計（出勤日数・総実働・総残業・警告ライン 45時間・深夜）と凡例が出た。
- [x] **修正申請と承認（F7・F8）**
  - 花子で 11/2 を退勤が出勤より前で送ると、422 で「退勤時刻は出勤時刻より後にしてください…」と出た。理由を空にすると、ブラウザの必須チェックで止まった。
  - 正しく送ると、302 で `/requests` に移り、「承認待ち」と出た。
  - 同じ日にもう一度申請しようとすると、既存の申請へ移されて「すでに承認待ちの修正申請があります」と出た。
  - 今の記録と同じ内容で申請すると、「今の記録と同じ内容です」と出た。
  - 取り下げ：確認ダイアログでキャンセルすると、何も変わらない。承諾すると「取り下げました」と出て、状態は「取り下げ」になった。
  - 管理者（次郎）の承認画面：ナビの「管理」に件数のバッジが出る。コメントを空にして「却下する」を押し、ダイアログを承諾すると、422 で「コメントを入力してください」と出て、承認待ちのままだった。コメントを入れると却下できた。
  - 承認：11/1 の退勤を 00:01 → 00:02 にする申請を承認した。月次集計の花子の総実働が 47:02 → 47:03 に変わった（反映を確認）。その後、00:01 に戻す申請を出して承認し、元に戻した（DB で `clock_out_at = 00:01` を確認）。
- [x] **休暇と有給（F9・F10）**
  - 有給・全日で 11/20〜11/24 を入れると、画面に「日数：2日（土日・祝日を除く）・期間 5日間・祝日：11/23 勤労感謝の日」と出た。
  - 11/21〜11/23 で送ると、422 で「休日だけの期間は申請できません」と「期間が重なっています」の2件が出た。
  - 残り 10.5日・申請できる残り・当年度の取得が表示された。
  - 従業員一覧に「有給の残り」「当年度の取得」「5日未満」「当年度の付与なし」が出た。
- [x] **シフト（F11・F12）**
  - シフト作成（11/23 の週）：11/23 の見出しは赤で「勤労感謝の日」、土曜は青。日ごとの人数、休暇のマス、パターンが出た。
  - マスを押すと登録画面に移った。開始と終了を同じ時刻にすると、422 で「終了時刻が開始時刻と同じです」と出た（保存はしていない）。
  - 従業員のシフトのカレンダー：11/23 は `shift-calendar__day--holiday` で「勤労感謝の日」と出た。
- [x] **ダッシュボード（F13）**：状態ごとの人数（退勤済み 4名・未出勤 1名など）、承認待ち、退勤漏れ、残業の警告、今日の一覧が出た。
- [x] **月次集計・締め・CSV（F14・F15）**
  - 11月度は「未締め」。10月度は「締め済み（山田 太郎 が 11/25 14:00 に締めました）」。
  - 「締めを解除する」の確認ダイアログが出た。キャンセルすると、締め済みのままだった。
  - CSV（リンクを押すとダウンロードが始まる）：
    - 従業員別の集計：`勤怠集計_2026年11月度_未締め.csv`
    - 日別の明細：`勤怠明細_2026年11月度_未締め.csv`（151行）
    - 10月度：`勤怠集計_2026年10月度.csv`
    - いずれも `text/csv; charset=utf-8`、先頭は BOM（`efbbbf`）。花子の総実働 47:03 は画面と一致した。
  - 従業員（花子）で CSV の URL を開くと、ホームに戻され「この画面を表示する権限がありません。」と出た。
- [x] **通知（F16）**
  - ベルを押すと一覧が開き、新しい順に日時つきで並んでいた。
  - 未読の「休暇の申請が却下されました（10/27）」を押すと `/requests/64` に移り、未読は 2 → 1 になった。
  - 新しい申請を出すと、管理者のベルの件数が増えた（29 → 30）。
- [x] **アカウント情報（F2 追加分）**
  - 歯車から `/account` に移った。基本情報・有給（残り 10.5日、取得 7.5日）・パスワード・アカウントの状態が出た。
  - 入力欄は0個（閲覧専用）。
- [x] **設定（F6）**：所定を 25:00 にして保存すると、422 で「24:00 以下にしてください」と出た。DB の設定は変わっていない（`updated_at` は 2026-11-13 のまま）。
- [x] **Turbo の画面の移動と戻る操作**：ナビのリンクで移動した後、ブラウザの「戻る」で前の画面（ホーム）が正しく出た。
- [x] **375px**：次の13画面で `scrollWidth = clientWidth = 375`（横スクロールなし）。ホーム・勤怠履歴・シフト・申請・休暇・通知・アカウント・ダッシュボード・承認・従業員・シフト作成・月次集計・設定。管理メニューの開閉と項目の表示も正常。
- [x] **DEV_NOW**：`DEV_NOW="2026-11-23 21:59:30"` で起動した。画面上部に「開発用：アプリの時計を DEV_NOW で変更して動作中です（現在 2026年11月23日(月) 21:59:35）」と出て、ホームの日付と時計もその時刻になった（表示だけ確かめ、打刻はしていない）。
- [x] **サーバーのログ**：1回目の起動では 116件のリクエストを処理した。内訳は 200 が 78、302 が 20、303 が 10、422 が 8。500 と例外は無い。404 は、私が誤って開いた `/admin` と、ブラウザが自動で取りに行く `/favicon.ico` だけ。sprockets のキャッシュの `Permission denied` は、2回の起動とも出なかった。

### DB の状態（読み取りだけで確認）
- 勤務ルール：所定 480分・休憩 60分・締め日 nil（月末）・警告ライン 45。`updated_at` は前と同じ。
- 締め：締め済み（解除されていない）なのは 2026年10月度だけ。11月度の締めの記録は無い。
- 件数の前後の比較：
  - approval_requests +4（却下1・取り下げ1・承認2）
  - attendances +1・attendance_breaks +1（次郎の今日の打刻）
  - notifications +11
  - いずれも画面の操作によるもの。そのほかのテーブルは変わっていない。
- 花子の 11/1 の勤怠は元の 00:00〜00:01 に戻した。

## バグ（重要度順）
重大・中のバグは無い。

1. **[軽微・アプリの不具合ではない] 開発用 DB の `admin@example.com` に `password123` でログインできない**
   - 再現手順：`/login` で `admin@example.com`／`password123` を入れる。
   - 期待される動作：sprint-17 の評価では、この組み合わせでログインしている（sprint-17-eval.md の 79行目・243行目）。
   - 実際の動作：「メールアドレスまたはパスワードが正しくありません。」と出る。`bin/rails runner` で調べると、`password123` でも `hanako2026` でも認証できない。User#1 の `updated_at` は 2026-11-26 05:24:08 で、sprint-17 の評価の最後の記録（04:11）より後。
   - 評価レポートには、admin のパスワードを変えたという記録は無い。誰がいつ変えたかは分からない。Rails のバージョンアップとは関係なく、データの状態の問題と判断した。DB は書き換えていない。

## 改善点（ジェネレーターへの具体的な指示）
- 必須ではない。ログインの回数制限（`SessionsController` の `rate_limit`）を確かめるテストがリポジトリに無い。テスト環境は `null_store` なので、Rails を上げてキャッシュのキーなどが変わっても気づけない。`test/controllers/sessions_controller_test.rb` に、`SessionsController.cache_store` の `increment` をメモリのストアに差し替えたうえで「10回の失敗の後の11回目で『ログインの試行回数が多すぎます』に移る」ことを確かめるテストを1件足すとよい（今回の評価で、一時テストとして同じ方法が動くことを確かめた）。
- 必須ではない。brakeman の Ruby2Shell（Ruby 3.4.9 の CVE）は残っている。Ruby の更新は別の作業として検討する。
- 必須ではない。オーケストレーターに伝えること：開発用 DB の admin のパスワードが不明。次からの検証は `jiro@example.com` を管理者として使うか、ユーザーの判断で再設定する。

## テスト実行結果
- `bin/rails test:system`（`tmp/sprint18/system.sh`、3回連続）
  - 1回目：62 runs, 1923 assertions, 0 failures, 0 errors, 0 skips
  - 2回目：62 runs, 1923 assertions, 0 failures, 0 errors, 0 skips
  - 3回目：62 runs, 1923 assertions, 0 failures, 0 errors, 0 skips
- `bin/rails test`：783 runs, 9643 assertions, 0 failures, 0 errors, 0 skips（deprecation 0件）
- 同時実行のテスト（単体で3回ずつ）：approval 3・leave 6・monthly_closing 3・overtime_alert 2・paid_leave 9・shift 5・sqlite_lock_wait 4 runs。21回すべて 0 failures, 0 errors。
- 回数制限の一時テスト（`tmp/`、確認後に削除）：1 runs, 14 assertions, 0 failures
- `bin/rubocop`：237 files inspected, no offenses detected
- `bin/brakeman`：Security Warnings 3（main では 4。EOLRails が消えた）
- 後片付け
  - 開発サーバーは2回とも停止した（3000番で待ち受けるプロセスなし）。ruby と chromedriver のプロセスも残っていない。
  - `tmp/pids/server.pid` は削除した。評価の開始時にも、前のサーバーの残り（PID 27416、プロセスなし）があったので削除してから起動した。
  - Playwright のブラウザは閉じた。今回の作業で `.playwright-mcp/` に増えたファイルは削除した。
  - 作業のログとスクリーンショットは `tmp/sprint18/` にある。
