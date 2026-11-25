# 勤務ルール設定：1日の所定労働時間・標準の休憩時間・締め日・残業時間の警告ラインを表示・保存する
class Admin::WorkRuleSettingsController < Admin::BaseController
  # 残業の計算や警告ラインに関わる設定（変えたら残業の警告を判定し直す）
  OVERTIME_RELATED_ATTRIBUTES = %w[scheduled_work_minutes closing_day overtime_warning_hours].freeze

  before_action :set_setting

  def show
  end

  def update
    # 画面を通さずに、設定の項目をまったく含まないリクエストが届いたとき（400 の素のエラー画面にしない）
    unless params[:work_rule_setting].respond_to?(:permit)
      flash.now[:alert] = "保存する内容が送信されませんでした。入力欄に値を入れて「保存する」を押してください。"
      return render :show, status: :unprocessable_entity
    end

    @setting.assign_attributes(setting_params)
    @setting.updated_by = current_user

    if save_setting
      check_overtime_alerts
      redirect_to admin_work_rule_setting_path, notice: saved_message
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def set_setting
    @setting = WorkRuleSetting.current
  end

  # まだ1件も保存されていないときに2人の管理者が同時に保存すると、一意制約で後の1件が失敗する。
  # その場合は先に保存された設定に同じ値を書き込む
  def save_setting
    @setting.save
  rescue ActiveRecord::RecordNotUnique
    attributes = @setting.attributes.slice(*WorkRuleSetting::CHANGE_LABELS.keys.map(&:to_s))
    @setting = WorkRuleSetting.current
    @setting.assign_attributes(attributes.merge("updated_by" => current_user))
    @setting.save
  end

  # 残業の計算や警告ラインに関わる設定（所定労働時間・締め日・警告ライン）を変えたら、全員の今月度の残業の警告を判定し直す。
  # 警告ラインを下げて超えた人には、まだ送っていない段階の通知が届く。失敗しても設定の保存は取り消さない（F16）
  def check_overtime_alerts
    return unless (@setting.saved_changes.keys & OVERTIME_RELATED_ATTRIBUTES).any?

    OvertimeAlert.check_all
  end

  def saved_message
    changes = @setting.saved_change_descriptions
    return "勤務ルールを保存しました（変更はありません）。" if changes.empty?

    "勤務ルールを保存しました（#{changes.join('、')}）。勤怠履歴の計算に反映されます。"
  end

  def setting_params
    params.require(:work_rule_setting)
          .permit(:scheduled_work_time, :standard_break_time, :closing_day, :overtime_warning_hours)
  end
end
