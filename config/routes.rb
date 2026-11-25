Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  # 初期セットアップ（最初の管理者作成）
  resource :setup, only: %i[show create]

  # ログイン・ログアウト
  get "login", to: "sessions#new", as: :login
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy", as: :logout

  # 打刻（出勤・退勤・休憩開始・休憩終了）。結果はホーム画面に戻って表示する
  resource :clock_in, only: :create
  resource :clock_out, only: :create
  resource :break_start, only: :create
  resource :break_end, only: :create

  # 自分の勤怠履歴（月次）。?month=2026-11 で月を選ぶ（省略時は今月）
  resources :attendances, only: :index

  # 自分のシフト（/shifts?month=2026-11）。公開済みのシフトを月のカレンダーで見る（省略時は今月）
  resources :shifts, only: :index

  # 申請（/requests）。打刻修正申請の入力は /requests/corrections/new?date=2026-11-10
  # （/requests/:id より先に定義する）
  resources :attendance_correction_requests, only: %i[new create], path: "requests/corrections"
  resources :approval_requests, only: %i[index show], path: "requests", constraints: { id: /\d+/ } do
    # 本人による取り下げ
    resource :withdrawal, only: :create, module: :approval_requests
  end

  # 休暇（/leaves）：休暇の申請と、自分の休暇の一覧。
  # 承認済みの休暇の取消申請は POST /leaves/:id/cancellation（詳細は /requests/:id で見る）。
  # GET（URL を直接開いた・再読み込みした）ときは、休暇の詳細へ戻す
  resources :leave_requests, path: "leaves", only: %i[index create], constraints: { id: /\d+/ } do
    resource :cancellation, only: %i[show create], module: :leave_requests
  end

  # 自分のパスワード変更
  resource :password, only: %i[edit update]

  # アプリ内通知（/notifications?page=2）。自分が受け取った通知の一覧（新しい順）。
  # 通知を開く：POST /notifications/:id/reading（既読にして、関連する画面へ移る）。
  # すべて既読にする：POST /notifications/read_all。
  # GET（URL を直接開いた・再読み込みした）ときは、既読にせずに通知の一覧へ戻す
  scope "notifications", module: :notifications, as: :notifications do
    resource :bulk_reading, path: "read_all", only: %i[show create]
  end
  resources :notifications, only: :index do
    resource :reading, only: %i[show create], module: :notifications, constraints: { notification_id: /\d+/ }
  end

  # 管理者用の画面
  namespace :admin do
    # ダッシュボード（/admin/dashboard）：今日の全員の状態と、対応が必要な事項（承認待ち・退勤漏れ・残業の警告）
    resource :dashboard, only: :show
    # 前日以前の退勤漏れの一覧（/admin/missing_clock_outs）
    resources :missing_clock_outs, only: :index

    resources :employees, only: %i[index new create edit update] do
      scope module: :employees do
        resource :password, only: %i[edit update]
        resource :activation, only: %i[create destroy]
        # 有給休暇の付与（/admin/employees/:id/paid_leaves）。残日数・付与の一覧・履歴を見て、付与を登録する。
        # 付与の削除（/admin/employees/:id/paid_leaves/:grant_id/removal/new）は、理由を入れて送る（行は消さずに記録する）
        resources :paid_leave_grants, path: "paid_leaves", only: %i[index create] do
          resource :removal, only: %i[show new create], controller: "paid_leave_grant_removals"
        end
      end
    end

    # シフト作成（/admin/shifts?week=2026-11-23）。週の表を見て、マスごとにシフトを登録・変更・削除する。
    # 前週のコピー（POST /admin/shifts/copy）・週の公開（POST /admin/shifts/publication）・パターンの割り当て
    # （POST /admin/shifts/assignments）は、/admin/shifts/:id より先に定義する。
    # これらの URL を直接開いた（GET）ときは、シフト表に戻す
    scope "shifts", module: :shifts, as: :shifts do
      resource :copy, only: %i[show create]
      resource :publication, only: %i[show create]
      resources :assignments, only: %i[index create]
    end
    resources :shifts, only: %i[index new create edit update destroy], constraints: { id: /\d+/ }
    # 予実の確認（/admin/shift_reports?month=2026-11）。従業員ごと・月度ごとの遅刻・早退・欠勤の回数と、
    # 従業員の日ごとの予定（シフト）と実績（打刻）（/admin/shift_reports/:id。:id は従業員）
    resources :shift_reports, only: %i[index show], constraints: { id: /\d+/ }
    # シフトパターン（/admin/shift_patterns）。よく使う時間帯（早番 9:00〜18:00 など）を登録する
    resources :shift_patterns, only: %i[index create edit update destroy], constraints: { id: /\d+/ }

    # 月次集計と締め（/admin/monthly?month=2026-11）。月度ごとの従業員別の集計と、締めの状態・警告。
    # 締める：POST /admin/monthly/closing（month=2026-11）、解除：DELETE /admin/monthly/closing（同じ）。
    # GET（URL を直接開いた・再読み込みした）ときは、月次集計に戻す。
    # 従業員の日別の勤怠は /admin/monthly/:id?month=2026-11（:id は従業員）
    resource :monthly_closing, path: "monthly/closing", only: %i[show create destroy]
    # CSV の書き出し（/admin/monthly/exports/summary.csv?month=2026-11）。summary＝従業員別の集計、daily＝日別の明細。
    # 拡張子は .csv だけ（.json や拡張子なしは 404）
    resources :monthly_exports, path: "monthly/exports", only: :show, format: true, constraints: { id: /summary|daily/, format: "csv" }
    resources :monthly_summaries, path: "monthly", only: %i[index show], constraints: { id: /\d+/ }
    # 管理者による勤怠の直接修正（/admin/attendance_records/:user_id/2026-11-10/edit）。理由が必須で、履歴を残す
    scope "attendance_records/:user_id/:date", constraints: { user_id: /\d+/, date: /\d{4}-\d{2}-\d{2}/ } do
      get "edit", to: "attendance_records#edit", as: :edit_attendance_record
      patch "", to: "attendance_records#update", as: :attendance_record
      delete "", to: "attendance_records#destroy"
    end

    # 勤務ルール設定（/admin/settings）。設定は組織で1件だけなので単数のリソース
    resource :work_rule_setting, only: %i[show update], path: "settings"

    # 承認（/admin/approvals）。承認・却下は POST /admin/approvals/:id/review（decision=approve|reject）
    # 承認済みの休暇の直接取消は POST /admin/approvals/:id/cancellation（理由が必須）。
    # GET（URL を直接開いた・再読み込みした）ときは、休暇の詳細へ戻す
    resources :approval_requests, path: "approvals", only: %i[index show], constraints: { id: /\d+/ } do
      resource :review, only: :create, module: :approval_requests
      resource :cancellation, only: %i[show create], module: :approval_requests
    end
  end

  root "home#show"
end
