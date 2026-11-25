# スプリント 17.1 実装レポート：システムテストの不安定さの修正

対象：`sprint-17-eval.md` の第3回評価の「テストの不安定さ（[軽微]、既存のテスト）」。アプリ本体（`app/`）は変更していない。

## 原因
1. **ログアウトの完了を待たずに次のログインへ進んでいた（主な原因）**
   - ヘッダーの「ログアウト」は `button_to` の DELETE で、Turbo が fetch で送る。`click_on "ログアウト"` は送信を始めるだけで、完了を待たない。
   - 直後の `log_in_as` が `visit login_path` すると、送信中の fetch が打ち切られることがある。すると、ログアウトの応答（セッションのクッキーの削除）がブラウザに反映されない。
   - その結果、ログインしたままログイン画面を開き、`redirect_if_logged_in` でホームに移される。そこで「メールアドレス」の欄が見つからず、`Capybara::ElementNotFound` になる。評価で記録された2件の失敗と同じ症状。
   - 該当箇所は8か所。`notifications_test.rb` 2か所、`leaves_test.rb` 4か所、`approvals_test.rb` 1か所、`account_test.rb` 1か所。
   - `notifications_test.rb`・`account_test.rb` の 375px のテストは、ループの最後にもログアウトを押して、そのまま終わっていた。このときは DELETE の処理中にテストの後始末が走るため、別のテストのエラーとして出る可能性もある。名前が分かっていない3件目の失敗は、これか、下の2の可能性がある（推定。再現はできていない）。
2. **画面の移動（Turbo のリンク）の完了を待たずに `visit` や次のクリックをしていた**
   - `correction_requests_test.rb`：ナビの「勤怠履歴」を押した直後に `visit @history_path` をしていた。
   - `shifts_test.rb`：管理メニューの「シフト作成」を押した直後に `visit admin_shifts_path(...)` をしていた。
   - `shift_checks_test.rb`：ナビの「シフト」を押したあと、移動を待つ確かめ方が `if past.month == Date.current.month` の条件付きだった。そのため、月の1日には待たずに `visit` していた（日付に依存する）。
   - `attendance_history_test.rb`：「翌月 →」を押した直後に「今月」を押していた。移動の途中だと、前の画面のリンクを押すおそれがある。

## 実装内容
- `test/application_system_test_case.rb` に、共通のヘルパーを `private` で追加した。
  - `log_in_as(user, password: "password123")`：これまでと同じ操作。最後に「ログインしました。」を待つ。
  - `log_out`：ヘッダーの中で「ログアウト」を押す。`assert_current_path login_path` と `assert_text "ログアウトしました。"` で、完了を待つ。完了を待つ理由も、コメントに書いた。
- 17ファイルにあった同じ内容の `log_in_as` と、3ファイルにあった `log_out`（待ち方がファイルごとに違った）を削除した。共通のヘルパーに一本化した。
  - `employee_management_test.rb` には、ログインの失敗を確かめる `log_in_with` が要るので残した。
- 待たずに `click_on "ログアウト"` していた上記8か所は、`log_out` に置き換えた。
- 画面の移動のあとの待ちを、次のとおり足した（すべて Capybara の待つ確かめ方。`sleep` は使っていない）。
  - `correction_requests_test.rb`：`assert_selector "[data-testid='period-label']"`。申請一覧の画面には無い要素。
  - `shifts_test.rb`：`assert_selector "h1", text: "シフト作成"`
  - `shift_checks_test.rb`：条件なしの `assert_selector "[data-testid='calendar-day']"`。シフトの画面だけにある要素。元の条件付きの確かめは残した。
  - `attendance_history_test.rb`：翌月の `period-label` を確かめてから「今月」を押す。
- `authentication_test.rb` のログアウトは、ログアウトそのものを確かめるテストで、直後に `assert_selector "h1", text: "ログイン"` と「ログアウトしました。」で待っている。そのため変更していない。

### 点検したが変更しなかった箇所（理由）
- `visit` の直後の `visit`（`paid_leaves_test.rb` 176〜177行目など）：`visit` は読み込みの完了まで待つので、競合しない。
- `shift_checks_test.rb` のトースト（5秒で自動で消える）の「×」を押す箇所：直前の確かめは、マスの表示と1回の位置の測定だけで、すぐに押している。5秒を超えるおそれは小さいため、そのままにした（下の「既知の問題」参照）。
- 時刻に依存する箇所：`dashboard`・`monthly_closings`・`monthly_exports` は `travel_to` で固定している。ほかの箇所も `Date.current` を基準にしていて、日付をまたぐ実行でなければ問題はない。
- テストの順番への依存：`DevelopmentClock.offset` と表示幅の変更は、`ensure` や `teardown` で元に戻している。問題は見つからなかった。
- ログインの回数の制限（`rate_limit`）：テスト環境の `cache_store` は `:null_store` なので、制限は働かない。

## 受け入れ基準の自己チェック
- [x] `test/system/` のすべてのファイルを点検し、ログアウトの直後・画面の移動の直後に待たずに進む箇所を、すべて直した。全18ファイルを読み、`click_on "ログアウト"` と `visit` を grep して確かめた。
- [x] 待ち方は `assert_text`・`assert_current_path`・`assert_selector` だけを使い、`sleep` は使っていない。
- [x] ログインとログアウトの処理を、`ApplicationSystemTestCase` の共通のヘルパーにまとめた。
- [x] `bin/rails test:system` を全体で5回続けて実行し、5回とも失敗0件・エラー0件だった。
- [x] `bin/rails test`・`bin/rubocop` が通る。
- [x] アプリ本体（`app/`）は変更していない（原因はテスト側だったため）。

## 自己評価（各 1〜10）
| 基準 | 点 | 根拠 |
|---|---|---|
| 機能性 | 8 | 5回続けて全件が通った。ただ、修正前の失敗も2回の実行で1〜2件という頻度だった。そのため、5回だけで「完全に直った」とは言い切れない。 |
| プロダクトの深さ | 7 | 指摘された2か所だけでなく、同じ形の8か所と、画面の移動の競合4か所（日付に依存する1か所を含む）も直した。 |
| UI/UX デザイン | - | テストだけの変更で、画面は変えていない（評価の対象外）。 |
| コード品質 | 8 | 17ファイルに重複していたヘルパーを一本化し、待つ理由をコメントに書いた。差分は、追加が約30行・削除が約140行。 |

## 動作確認の方法
- 開発サーバーは不要。`bin/rails test:system` を全体で実行する（`bin/rails test` と同時に実行しないこと）。
- 修正前の症状が出た2つのテスト：
  - `NotificationsTest`「通知の一覧で『すべて既読にする』と…」
  - `LeavesTest`「未来の承認済みの休暇に取消申請を出し…」
- 共通のヘルパー：`test/application_system_test_case.rb` の `log_in_as`・`log_out`

## 実行したテストと結果
- `bin/rubocop`：238 files inspected, no offenses detected
- `bin/rails test`：784 runs, 9650 assertions, 0 failures, 0 errors, 0 skips
- `bin/rails test:system`（5回続けて実行。`bin/rails test` とも開発サーバーとも同時には実行していない。ログは `tmp/s17_1_system_run1.log`〜`run5.log`）

  | 回 | runs | assertions | failures | errors | skips | 時間 |
  |---|---|---|---|---|---|---|
  | 1 | 62 | 1923 | 0 | 0 | 0 | 177.1s |
  | 2 | 62 | 1923 | 0 | 0 | 0 | 175.9s |
  | 3 | 62 | 1923 | 0 | 0 | 0 | 176.4s |
  | 4 | 62 | 1923 | 0 | 0 | 0 | 177.3s |
  | 5 | 62 | 1923 | 0 | 0 | 0 | 177.2s |

## 既知の問題・懸念
- 修正前の失敗は確率的だった（2回の実行で1件と2件）。5回の成功で、再発の可能性は大きく下がった。ただ、ゼロとは断定できない。
- 名前の分かっていない3件目の失敗は、特定できていない。上記の「ループの最後のログアウト」か「画面の移動の競合」のどれかと推定している。どれも今回直した。
- `shift_checks_test.rb` のトーストの「×」を押す確かめは、トーストが5秒で消えるため、マシンが極端に遅いと失敗しうる。今回の5回では問題は出なかった。
- `assert_no_horizontal_scroll` も各ファイルに重複している。ただ、今回の不安定さとは関係が無いので、範囲を広げないため、まとめていない。
- 一時スクリプト `tmp/remove_login_helpers.rb` を作った（`tmp/` は git の対象外）。このスクリプトが一度、改行を CRLF に変えたので、LF に戻した。差分は、意図した行だけになっている。
