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

  # 管理者用の画面
  namespace :admin do
    resources :employees, only: %i[index new create edit update] do
      scope module: :employees do
        resource :password, only: %i[edit update]
        resource :activation, only: %i[create destroy]
      end
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
