# スプリント 17.1 評価：システムテストの不安定さの修正

## 判定：合格

両方のブランチで `bin/rails test:system` を3回ずつ続けて実行し、6回とも失敗0件・エラー0件だった。一方、修正前の `feature/kintai-app` では、1回の実行で前回と同じエラー（`LeavesTest`、`Unable to find field "メールアドレス"`）が再現した。修正の中身も、原因（ログアウトと画面の移動の完了を待っていないこと）に正しく対応している。テストの数は減っておらず、確かめる内容も弱くなっていない。

## 採点
| 基準 | 点 | 閾値 | 判定 | 根拠 |
|---|---|---|---|---|
| 機能性 | 9 | 8 | 合格 | `fix/system-test-flakiness` で 51 runs × 3回、`feature/account-page` で 62 runs × 3回、すべて 0 failures・0 errors。修正前の `feature/kintai-app` では 51 runs・1 error で、症状が再現した。修正の前後で、同じ環境の結果が分かれた。確率的な不具合なので、6回で「ゼロ」とは言い切れない。そのため10点にはしなかった。 |
| プロダクトの深さ | 7 | 6 | 合格 | アプリ（`app/`）に変更が無いため、`sprint-17-eval.md` 第3回評価の値（7）を引き継ぐ。 |
| UI/UX デザイン | 7 | 6 | 合格 | 同上。第3回評価の値（7）を引き継ぐ。 |
| コード品質 | 8 | 7 | 合格 | 17〜19ファイルに重複していた `log_in_as`、待ち方がばらばらだった3つの `log_out` を、`ApplicationSystemTestCase` に一本化した。`sleep` は使わず、Capybara の待つ確かめ方だけを使っている。待つ理由をコメントに書いた。`bin/rails test`・`bin/rubocop` は両方のブランチで通る。減点したのは次の点。`assert_no_horizontal_scroll` の重複が残る。`log_in_as` の `password:` 引数は、今のところどこからも使われていない。 |

## 受け入れ基準の検証結果
- [x] ログアウトの直後・画面の移動の直後に、待たずに進む箇所が直っている
  - `feature/account-page` で `test/system/` を grep した。`click_on "ログアウト"` が残るのは `authentication_test.rb:21` だけ。ここはログアウトそのものを確かめるテストで、直後に「ログイン」の見出しと「ログアウトしました。」を確かめている。そのため、問題は無い。
  - 各ファイルの `def log_in_as` / `def log_out` は無くなった。残るのは `employee_management_test.rb` の `log_in_with`（ログインの失敗を確かめるため）だけ。
- [x] 待ち方は `assert_*` だけで、`sleep` を使っていない
  - `test/system` と `test/application_system_test_case.rb` に `sleep` は無い（grep）。
- [x] 共通のヘルパー `log_out` が、ログアウトの完了を待っている
  - `within(".header") { click_on "ログアウト" }` のあと、`assert_current_path login_path` と `assert_text "ログアウトしました。"` で待つ。応答が返り、移動が終わるまで次に進まない。前の `paid_leaves_test.rb` の版（`assert_text` だけ）や `leave_direct_cancellations_test.rb` の版（`assert_field` だけ）より強い。
- [x] 画面の移動の待ち方が、移動先にしか無い要素を確かめる形になっている（ビューを読んで確かめた）
  - `correction_requests_test.rb`：`[data-testid='period-label']`。これがあるのは、勤怠履歴・月次の集計・シフトの報告の画面だけ。移る前の申請一覧（`attendance_correction_requests`）には無い。
  - `shifts_test.rb`：`h1` の「シフト作成」。これがあるのは `admin/shifts/index` だけ。移る前の管理者のダッシュボードの `h1` は「ダッシュボード」。
  - `shift_checks_test.rb`：`[data-testid='calendar-day']`。これは `shifts/_day.html.erb` にしか無い。移る前のホーム（`h1` は「ホーム」）には無い。前は月の1日には待っていなかったが、条件なしで待つようになった。
  - `attendance_history_test.rb`：翌月の `period-label` の文字を確かめる。前の画面（今月）とは文字が違う。部分一致で取り違えるおそれも点検した。たとえば「YYYY年1月」が「YYYY年1x月」に一致するのは、前の画面が同じ年の10〜12月のときだけ。翌月が1月なら、前の画面は前の年の12月になる。そのため、この取り違えは起きない。
- [x] テストの意味が弱くなっていない
  - 差分で消えた行は、各ファイルのヘルパーの定義と、`click_on "ログアウト"` の1行だけ（`log_out` に置き換え）。足された行は、すべて確かめを足すもの。`assert_*` は1つも消えていない。
  - assertions の数は、`fix/system-test-flakiness` で 652。修正前の `feature/kintai-app` は 618 だったが、これは1件がエラーで途中で止まった回の数。
- [x] テストが減っていない
  - `feature/kintai-app`（修正前）：51 runs。`fix/system-test-flakiness`：51 runs（同じ）。
  - `feature/account-page`：62 runs。`git grep` で数えた `test "` の数（51 / 51 / 62）とも合う。第3回評価の 62 runs とも同じ。
- [x] ブランチの分け方が妥当
  - `git diff feature/kintai-app fix/system-test-flakiness` の対象は、`application_system_test_case.rb`、F1〜F16 の15ファイル、`sprint-17.1-report.md` だけ。`account_test.rb`・`header_layout_test.rb`、アカウント情報画面のテスト・ビューは含まれていない。
  - `9956168` の変更は、`account_test.rb`（375px のループの最後を `log_out` にし、ヘルパーを削除）と `header_layout_test.rb`（ヘルパーを削除）だけ。この2ファイルは `feature/account-page` にしか無い。
  - `git diff fix/system-test-flakiness feature/account-page -- test/` の残りの差分は、`796fa7f`（アカウント情報画面）で足されたテストだけ。たとえば `employee_management_test.rb` の「パスワードを変更する」への経路の変更がある。共通の修正の漏れは無い。

## バグ（重要度順）
- 重大・中のバグは無し。
1. **[軽微]** `shift_checks_test.rb` のトースト（5秒で消える）の「×」を押す確かめが、極端に遅い環境では失敗しうる（レポートの既知の問題のとおり）。今回の6回の実行では出なかった。

## 改善点（ジェネレーターへの具体的な指示）
- （任意）各ファイルに重複している `assert_no_horizontal_scroll` を、`ApplicationSystemTestCase` の `private` にまとめる。
- （任意）`log_in_as` の `password:` 引数は、使う場面ができるまで外してよい。残す場合は、使うテストを書く。
- （任意）`shift_checks_test.rb` のトーストの「×」の確かめは、表示の直後にまず押す順にする。または、テストの中だけ自動で消えるまでの時間を延ばせるようにする。

## テスト実行結果
（どれも、ほかのテストとも開発サーバーとも同時には実行していない。開発サーバーは起動していない。）

### `fix/system-test-flakiness`（`ca61c98`）
- `bin/rails test`：770 runs, 9508 assertions, 0 failures, 0 errors, 0 skips
- `bin/rails test:system`
  | 回 | runs | assertions | failures | errors | skips |
  |---|---|---|---|---|---|
  | 1 | 51 | 652 | 0 | 0 | 0 |
  | 2 | 51 | 652 | 0 | 0 | 0 |
  | 3 | 51 | 652 | 0 | 0 | 0 |
- `bin/rubocop`：234 files inspected, no offenses detected

### `feature/account-page`（`9956168`）
- `bin/rails test`：784 runs, 9649 assertions, 0 failures, 0 errors, 0 skips
- `bin/rails test:system`
  | 回 | runs | assertions | failures | errors | skips | 時間 |
  |---|---|---|---|---|---|---|
  | 1 | 62 | 1923 | 0 | 0 | 0 | 176.5s |
  | 2 | 62 | 1923 | 0 | 0 | 0 | 185.1s |
  | 3 | 62 | 1923 | 0 | 0 | 0 | 179.2s |
- `bin/rubocop`：238 files inspected, no offenses detected

### 比較：修正前の `feature/kintai-app`（`80cd998`）
- `bin/rails test:system`（1回）：51 runs, 618 assertions, 0 failures, **1 errors**, 0 skips（135.5s）
  - `LeavesTest#test_未来の承認済みの休暇に取消申請を出し、管理者が承認すると勤怠履歴から消える`：`Capybara::ElementNotFound: Unable to find field "メールアドレス" that is not disabled`。第3回評価で記録した症状と同じ。

### 作業後の状態
- `feature/account-page` に戻した。`git status` に、この評価ファイル以外の変更は無い。
