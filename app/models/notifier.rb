# アプリ内通知（F16）を作る。出来事ごとに、誰に・どんな通知を送るかを決める。
#
#   Notifier.request_submitted(request)            # 新しい申請 → 有効な管理者（申請した本人を除く）
#   Notifier.request_reviewed(request)             # 承認・却下 → 申請者
#   Notifier.leave_cancelled_by_admin(leave, ...)  # 管理者の直接取消 → 休暇の本人
#   Notifier.shifts_published(...)                 # シフトの公開・変更 → 変わった本人だけ
#   Notifier.paid_leave_granted(grant)             # 有給の付与 → 付与された本人
#   残業の警告は OvertimeAlert.check が作る（Notifier.overtime_alert）。
#
# 送る相手の決まり
# - 自分がした操作の通知は、自分には送らない（自己承認・自分の休暇の直接取消・自分への付与・自分のシフトの公開・自分の申請）。
#   有効な管理者が1人だけで、その管理者が自分の申請を出したときも送らない（出したのは本人で、承認の画面の件数にも出る）。
# - 無効なユーザー（ログインできない）には送らない。
#
# 失敗しても元の処理を失敗させない
# - 呼び出し側は、元の処理（承認など）のトランザクションが確定した「後」に呼ぶ。通知が作れなくても、元の処理は取り消されない。
# - 通知を作る処理は .safely の中で行う。例外はここで捕まえて記録（ログ・Rails.error）し、false を返す（呼び出し側には伝えない）。
#   1つの出来事の通知（管理者全員分など）は1つのトランザクション（requires_new のセーブポイント）で作るので、
#   途中で失敗したら、その出来事の通知はまとめて作られない（一部の人にだけ届く、ということがない）。
# - 元の処理が確定した後、通知を作る前にプロセスが止まった場合は、その通知は作られない（通知は補助の情報なので、作り直さない）。
class Notifier
  class << self
    # 例外を外に出さずに、ブロックの中の通知をまとめて作る。成功すれば true
    def safely(event)
      ApplicationRecord.transaction(requires_new: true) { yield }
      true
    rescue StandardError => error
      Rails.logger.error("[Notifier] #{event} の通知を作れませんでした: #{error.class}: #{error.message}")
      Rails.error.report(error, handled: true, context: { notifier_event: event })
      false
    end

    # 新しい申請が届いた → 有効な管理者全員（申請した本人を除く）
    def request_submitted(request)
      safely("新しい申請") do
        applicant = request.user
        title = "#{applicant.name} さんから#{request.kind_label}の申請が届きました"
        body = "対象日：#{request.target_label}。#{request_details(request)}理由：#{request.reason.truncate(80)}"
        recipients = User.active_admins.where.not(id: applicant.id).order(:id)
        recipients.each do |admin|
          deliver!(admin, kind: "request_submitted", title: title, body: body, actor: applicant, subject: request,
                          path: routes.admin_approval_request_path(request))
        end
      end
    end

    # 申請が承認・却下された → 申請者（自分で処理したときは送らない）
    def request_reviewed(request)
      return false unless request.processed?

      safely("申請の承認・却下") do
        applicant = request.user
        reviewer = request.reviewer
        next if reviewer && reviewer.id == applicant.id

        approved = request.approved?
        title = "#{request.kind_label}の申請が#{approved ? '承認' : '却下'}されました（#{request.target_label}）"
        body = +"#{reviewer&.name || '管理者'} さんが#{approved ? '承認' : '却下'}しました。"
        body << review_result_note(request) if approved
        body << "コメント：#{request.review_comment.truncate(120)}" if request.review_comment.present?
        deliver!(applicant, kind: approved ? "request_approved" : "request_rejected", title: title, body: body,
                            actor: reviewer, subject: request, path: routes.approval_request_path(request))
      end
    end

    # 管理者が承認済みの休暇を直接取り消した → 休暇の本人（自分の休暇を自分で取り消したときは送らない）。
    # 承認待ちの取消申請がいっしょに処理済みになった場合も、通知はこの1件にまとめる
    def leave_cancelled_by_admin(leave, admin:, closed_requests: [])
      safely("休暇の直接取消") do
        employee = leave.user
        next if admin.id == employee.id

        title = "休暇が管理者により取り消されました（#{leave.target_label}）"
        body = +"#{admin.name} さんが #{leave.target_label} の#{leave.day_label}を取り消しました。"
        body << "有給休暇の残日数に#{LeaveRequest.format_days(leave.chargeable_days)}戻りました。" if leave.leave_paid? && leave.chargeable_days.positive?
        body << "出していた取消申請は、この取消で処理済みになりました。" if closed_requests.any?
        body << "理由：#{leave.cancellation_reason.to_s.truncate(120)}"
        deliver!(employee, kind: "leave_cancelled_by_admin", title: title, body: body, actor: admin, subject: leave,
                           path: routes.approval_request_path(leave))
      end
    end

    # シフトの週を公開した → その公開で従業員に見えるシフトが変わった本人だけ。
    # changes … { user_id => { added: [日付], changed: [日付], removed: [日付] } }（従業員に見えていなかった下書きの削除は含めない）
    def shifts_published(week_start:, admin:, changes:)
      safely("シフトの公開") do
        users = User.active.where(id: changes.keys).index_by(&:id)
        week_label = "#{I18n.l(week_start, format: :short)}〜#{I18n.l(week_start + 6, format: :short)}"
        changes.sort.each do |user_id, dates|
          user = users[user_id]
          next if user.nil? || user.id == admin&.id

          first_publication = dates[:changed].empty? && dates[:removed].empty?
          kind = first_publication ? "shift_published" : "shift_changed"
          title = first_publication ? "シフトが公開されました（#{week_label}）" : "シフトが変更されました（#{week_label}）"
          body = shift_change_body(dates)
          first_date = dates.values.flatten.min
          deliver!(user, kind: kind, title: title, body: body, actor: admin,
                         path: routes.shifts_path(month: first_date.strftime("%Y-%m")))
        end
      end
    end

    # 有給休暇を付与した → 付与された本人（自分に付与したときは送らない）
    def paid_leave_granted(grant)
      safely("有給の付与") do
        employee = grant.user
        next if !employee.active? || grant.granted_by_id == employee.id

        title = "有給休暇が#{LeaveRequest.format_days(grant.granted_days)}付与されました"
        body = +"#{I18n.l(grant.granted_on, format: :long)} 付与・#{I18n.l(grant.expires_on, format: :long)} まで有効です。"
        balance = PaidLeaveAccount.new(employee).balance
        body << "今の残日数は#{LeaveRequest.format_days(balance)}です。"
        deliver!(employee, kind: "paid_leave_granted", title: title, body: body, actor: grant.granted_by, subject: grant,
                           path: routes.leave_requests_path)
      end
    end

    # 残業の警告（OvertimeAlert.check のトランザクションの中で呼ぶ）→ 本人と、有効な管理者全員（本人を除く）
    def overtime_alert(alert, user:, period:)
      level_label = alert.level == 100 ? "警告ライン（#{alert.warning_hours_label}）" : "警告ライン（#{alert.warning_hours_label}）の#{alert.level}%"
      overtime = duration(alert.overtime_minutes)
      if user.active?
        deliver!(user, kind: "overtime_alert", subject: alert, path: routes.attendances_path(month: period.to_param),
                       title: "#{period.label}の残業が#{level_label}を超えました",
                       body: "今の残業時間は #{overtime} です（#{period_range(period)}）。勤務の予定を見直してください。")
      end
      User.active_admins.where.not(id: user.id).order(:id).each do |admin|
        deliver!(admin, kind: "overtime_alert", subject: alert, path: routes.admin_monthly_summary_path(user, month: period.to_param),
                        title: "#{user.name} さんの#{period.label}の残業が#{level_label}を超えました",
                        body: "今の残業時間は #{overtime} です（#{period_range(period)}）。")
      end
    end

    private

    def deliver!(recipient, **attributes)
      return unless recipient.active?

      Notification.create!(recipient: recipient, **attributes)
    end

    def routes
      Rails.application.routes.url_helpers
    end

    def request_details(request)
      case request
      when LeaveRequest
        "#{request.day_label}・#{LeaveRequest.format_days(request.chargeable_days)}。"
      when LeaveCancellationRequest
        request.leave_request ? "取り消す休暇：#{request.leave_request.day_label}。" : ""
      else
        ""
      end
    end

    def review_result_note(request)
      case request
      when AttendanceCorrectionRequest then "勤怠記録が申請どおりに更新されました。"
      when LeaveRequest then "勤怠履歴に#{request.day_label}として表示されます。"
      when LeaveCancellationRequest then "休暇は取り消されました。"
      else ""
      end
    end

    def shift_change_body(dates)
      parts = { added: "追加", changed: "変更", removed: "削除" }.filter_map do |key, label|
        next if dates[key].empty?

        "#{label}：#{dates[key].sort.map { |date| I18n.l(date, format: :short_with_day) }.join('、')}"
      end
      "#{parts.join('／')}。「シフト」画面で確認してください。"
    end

    def duration(minutes)
      format("%d:%02d", minutes / 60, minutes % 60)
    end

    def period_range(period)
      "#{I18n.l(period.start_date, format: :short)}〜#{I18n.l(period.end_date, format: :short)}"
    end
  end
end
