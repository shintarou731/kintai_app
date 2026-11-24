# 開発環境専用：アプリの時計を指定した時刻から進める（日付をまたぐ打刻などを手で確かめるため）。
#
#   DEV_NOW="2026-11-23 21:59:30" bin/rails server -p 3000
#
# 起動した瞬間を DEV_NOW の時刻（日本時間）とみなし、以後は実際の時間の流れで進む。
# 本番・テスト環境では何もしない。有効な間は画面上部に注意書きを出す。
module DevelopmentClock
  mattr_accessor :offset

  def self.active?
    !offset.nil?
  end

  def self.start!(value)
    target = Time.find_zone!(Rails.application.config.time_zone).parse(value.to_s)
    raise ArgumentError, "DEV_NOW を時刻として解釈できません: #{value.inspect}" unless target

    # 過去の時刻にすると、マイグレーションのファイル名の日時が「未来」になり検証エラーになるため止める
    Rails.application.config.active_record.validate_migration_timestamps = false
    ActiveRecord.validate_migration_timestamps = false

    self.offset = target.to_f - Time.now.to_f
    shift = offset
    Time.singleton_class.prepend(Module.new do
      define_method(:now) { |*args, **kwargs| super(*args, **kwargs) + shift }
    end)
    Rails.logger&.warn("[DevelopmentClock] アプリの時計を #{target} から進めます")
  end
end

DevelopmentClock.start!(ENV["DEV_NOW"]) if Rails.env.development? && ENV["DEV_NOW"].present?
