# スプリント 1 実装レポート：初期セットアップとログイン（F1）

## 実装内容

- **ユーザーモデル**（`app/models/user.rb`、マイグレーション `db/migrate/20261124090757_create_users.rb`）
  - 項目：氏名・メールアドレス（一意・小文字/前後空白を正規化）・パスワード（`has_secure_password`、bcrypt で暗号化して保存）・役割（`employee` / `admin`、初期値は従業員）
  - パスワードは 8 文字以上（`User::PASSWORD_MIN_LENGTH`）。確認用パスワードとの一致も検証。
  - `User.setup_required?`（ユーザー0人か）、`User.authenticate_by_credentials`（ログイン判定）、`#role_label`（「管理者」「従業員」の表示名）
  - F2 で必要になる「有効/無効」の状態はまだ追加していない（F2 で追加予定）。
- **認証の仕組み**（`app/controllers/concerns/authentication.rb`）
  - セッションに user_id を保持。全画面で既定でログイン必須。
  - 未ログイン時：ユーザーが0人なら初期セットアップ画面（`/setup`）、それ以外はログイン画面（`/login`）へリダイレクト。
  - ログイン時に `reset_session` でセッションを作り直す（セッション固定攻撃の対策）。
  - ログイン前にアクセスしようとした画面（GET）へ、ログイン後に戻る。
- **初期セットアップ**（`SetupsController`、`GET/POST /setup`）
  - 氏名・メールアドレス・パスワード・パスワード確認を入力して作成。作成ユーザーは必ず管理者（`role` をパラメータで送っても無視）。作成後は自動ログインしてホームへ。
  - ユーザーが1人以上いるときは、表示・送信とも「初期セットアップは完了しています」とログイン画面へリダイレクト。保存直前にもトランザクション内で再確認する。
- **ログイン・ログアウト**（`SessionsController`、`GET/POST /login`、`DELETE /logout`）
  - 失敗時は理由を区別せず「メールアドレスまたはパスワードが正しくありません。」を表示（入力したメールアドレスは保持）。
  - ログイン試行の回数制限（3分で10回、Rails 7.2 の `rate_limit`）。※開発・テスト環境はキャッシュが null_store のため実際には発動しない。
  - ログイン済みでログイン画面を開くとホームへ。
- **ホーム画面**（`HomeController#show`、`/`）：骨格のみ。「ようこそ、○○ さん」＋役割バッジ＋今日の日付。打刻は後続スプリント。
- **共通レイアウト・ヘッダー**（`app/views/layouts/application.html.erb`、`app/views/shared/_header.html.erb`、`_flash.html.erb`、`_form_errors.html.erb`）
  - 上部固定ヘッダー：アプリ名「キンタイ帳」、ナビ領域（空。後続で追加）、ログイン中のユーザー名、管理者なら「管理者」バッジ、ログアウトボタン。
  - 操作結果のメッセージを画面上部に表示（成功＝緑、エラー＝赤）。
  - CSS（`app/assets/stylesheets/application.css`）：白〜淡いグレー基調、アクセントはティール。状態色（緑/黄/グレー/赤）を CSS 変数として定義。375px 幅で横スクロールが出ないことをシステムテストで確認。
- **日本語化・タイムゾーン**：`config.time_zone = "Tokyo"`、`default_locale = :ja`、`config/locales/ja.yml`（エラーメッセージ・項目名・日付形式）
- **gem**：`bcrypt` を有効化（Gemfile のコメントアウトを解除し `bundle install`）。

## 受け入れ基準の自己チェック

- [x] ユーザー0人でアクセスすると初期セットアップ画面（氏名・メール・パスワード・パスワード確認）が出る — `SetupsControllerTest`、システムテスト、スクリーンショットで確認
- [x] 初期セットアップ完了で管理者としてログイン済みになりホームへ遷移 — `SetupsControllerTest`（`user.admin?`、ヘッダーに氏名）、システムテスト
- [x] ユーザーが1人以上いると初期セットアップ画面はログイン画面へ移動し、POST しても作成されない — `SetupsControllerTest` の2件
- [x] 未ログインで任意の画面にアクセスするとログイン画面へ — `HomeControllerTest`（現時点の画面はホームのみ。以後の画面も `ApplicationController` 継承で既定でログイン必須）
- [x] 正しい組み合わせでログインでき、誤りは共通メッセージ — `SessionsControllerTest`（パスワード誤り・存在しないメール・空欄の3パターンで同一文言）
- [x] パスワード8文字未満は登録できずエラー表示 — `UserTest`、`SetupsControllerTest`（「パスワードは8文字以上で入力してください」）
- [x] ヘッダーのログアウトでログアウトしログイン画面へ — `SessionsControllerTest`、システムテスト
- [x] ログイン後のヘッダーにユーザー名表示 — `HomeControllerTest`、システムテスト

## 自己評価（各 1〜10）

| 基準 | 点 | 根拠 |
|---|---|---|
| 機能性 | 8 | 全受け入れ基準をテストで確認。異常系（空欄・確認不一致・重複作成・role 改ざん・削除済みユーザーのセッション）も対応。 |
| プロダクトの深さ | 7 | セッション固定対策、ログイン後の元画面への復帰、メールの正規化、試行回数制限まで実装。ホーム画面自体はまだ中身が薄い（後続スプリントで打刻を追加）。 |
| UI/UX デザイン | 7 | デザイン方針（白・淡グレー・ティール、上部メッセージ）に沿い、スマホ幅でも崩れない。ナビが空のためヘッダーはやや寂しい。未ログイン画面でフラッシュがロゴの上に出る配置は好みが分かれる。 |
| コード品質 | 8 | Rails 規約に沿った構成（concern・resource ルート・strong parameters）。モデル/コントローラ/システムテスト計35件。rubocop 指摘なし。 |

## 動作確認の方法

- 起動：`bin/rails server -p 3000`
- 開発 DB（`storage/development.sqlite3`）は現在ユーザー0人の状態（マイグレーション適用済み）。
- 手順
  1. `http://localhost:3000/` を開く → `/setup`（初期セットアップ）に移動することを確認。
  2. パスワードを7文字（例 `short12`）にして送信 → 「パスワードは8文字以上で入力してください」が出る。確認欄を不一致にすると「パスワード（確認）とパスワードの入力が一致しません」。
     - 補足：空欄は HTML の required 属性でブラウザが送信を止める。
  3. 正しく入力して「管理者アカウントを作成」→ ホーム（`/`）に移動、上部に完了メッセージ、ヘッダーに氏名と「管理者」バッジ。
  4. ヘッダーの「ログアウト」→ `/login` に戻り「ログアウトしました。」。
  5. `http://localhost:3000/setup` を開く → `/login` に移動し「初期セットアップは完了しています」。
  6. `http://localhost:3000/` を開く → `/login` に移動し「ログインしてください。」。
  7. 誤ったパスワード、存在しないメールで「メールアドレスまたはパスワードが正しくありません。」。正しい組み合わせでログインできる。
- DB 確認：`bin/rails runner "p User.pluck(:name, :email, :role)"`
- 注意：一度管理者を作ると、初期セットアップ画面を再確認するにはユーザーを消す必要がある（データ削除になるため、エバリュエーターはテストの結果で代替するか、オーケストレーター経由でユーザーに確認すること）。

## 実行したテストと結果

- `bin/rails test`：33 runs, 104 assertions, 0 failures, 0 errors, 0 skips（3回連続で成功）
- `bin/rails test:system`：2 runs, 13 assertions, 0 failures, 0 errors（ヘッドレス Chrome。初期セットアップ→ログアウト→ログイン失敗→成功の一連の流れ、375px 幅で横スクロールなし）
- `bin/rubocop`：39 files inspected, no offenses detected

## 既知の問題・懸念

- **テスト DB の準備**：最初の `bin/rails test` で「Migrations are pending」になったため `bin/rails db:test:prepare`（テスト用 DB のみスキーマ読込）を実行した。開発 DB には `bin/rails db:migrate` のみ実施。
- **Windows での初回テストの一時的エラー**：アセットキャッシュが空の状態で初回 `bin/rails test` を実行した際、sprockets キャッシュのファイル名変更で `Permission denied` が1件出た（Windows でのファイルロック競合）。再実行では再現せず、コードの問題ではないと判断。
- **システムテストの回避策**：Capybara 3.40 がテスト終了時に呼ぶ CDP コマンド `Storage.clearDataForOrigin`（origin `*`）を、インストール済みの Chrome 159 が受け付けずエラーになる。`test/application_system_test_case.rb` に、その場合だけクッキー全削除に切り替えるテスト専用のパッチを入れた。Capybara 更新で不要になる見込み。
- **ログイン試行回数制限**は開発・テスト環境のキャッシュ設定（null_store）では発動しないため、ブラウザでは確認できない。
- 「有効/無効」の状態や従業員の追加は F2 の範囲のため未実装。ヘッダーのナビ領域は空。
