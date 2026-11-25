# 有給休暇の付与と取得から、残日数を計算する（F10）。DB には残日数を保存せず、毎回ここで計算する。
#
#   ledger = PaidLeaveLedger.new(grants: user.paid_leave_grants, leaves: user.leave_requests.leave_paid.effective, today: Date.current)
#   ledger.balance  # => 15/2r（残り 7.5日）
#
# 計算のきまり
# - 日数は 0.5日を1単位とする整数（half_days）で数え、小数の誤差を出さない。
# - 休暇の日数は LeaveRequest#working_dates（休日＝土日・祝日を除いた日）× 1（全日）または 0.5（半休）。
# - 休暇の1日ごとに、その日に使える付与（付与日 ≦ その日 ≦ 有効期限）のうち、古い付与（付与日の早い順）から消化する。
#   休暇の日は日付の早い順に割り当てる。1日分が2つの付与にまたがることもある（0.5日ずつ）。
#   - 有効期限の日までは使える。有効期限の翌日の休暇には使えない。
#   - 付与日より前の休暇には使えない。
# - どの付与でも賄えない日数は「不足」（uncovered）として数える（付与が登録されていない時期の有給など）。
# - 残日数（balance）＝ 今日の時点で有効な付与（付与日 ≦ 今日 ≦ 有効期限）の、消化されていない日数の合計。
#   未来の日付の承認済みの休暇も、承認された時点で消化に数える（残日数が減る）。
#   有効期限が切れた付与の残りは「失効」として残日数に入れない。
# - 削除した付与（removed_at がある）は数えない（＝削除すると、その付与分は残日数から消える）。
# - 取り消された休暇（cancelled_at がある）・却下・取り下げの休暇は、呼び出し側が leaves に入れない（＝残日数が戻る）。
class PaidLeaveLedger
  HALF_DAY = 1/2r

  # 休暇の1日分が、どの付与から何単位（0.5日）消化されたか
  Allocation = Data.define(:grant, :half_days)
  # 1件の休暇の消化の内訳
  Usage = Data.define(:leave, :allocations, :uncovered_half_days) do
    def half_days
      allocations.sum(&:half_days) + uncovered_half_days
    end

    def grants
      allocations.map(&:grant).uniq
    end
  end

  attr_reader :grants, :leaves, :today

  def initialize(grants:, leaves:, today: Date.current)
    # 削除した付与（PaidLeaveGrant#removed?）は数えない。呼び出し側は kept で読むが、混ざっても計算に入れない
    @grants = grants.reject(&:removed?).sort_by { |grant| [ grant.granted_on, grant.expires_on, grant.id || 0 ] }
    @leaves = leaves.sort_by { |leave| [ leave.target_date, leave.id || 0 ] }
    @today = today
    allocate
  end

  # 0.5日の個数を日数（Rational）にする
  def self.days(half_days)
    half_days * HALF_DAY
  end

  # 休暇1日あたりの単位数（全日 2、半休 1）
  def self.half_days_per_date(leave)
    leave.half_day? ? 1 : 2
  end

  # 残日数（今日の時点で有効な付与の、まだ消化していない日数）
  def balance
    self.class.days(balance_half_days)
  end

  def balance_half_days
    grants.select { |grant| grant.usable_on?(today) }.sum { |grant| remaining_half_days(grant) }
  end

  # どの付与でも賄えなかった日数（付与を超えて取得した日数）
  def shortage
    self.class.days(uncovered_half_days)
  end

  def uncovered_half_days
    @usages.sum(&:uncovered_half_days)
  end

  def remaining_half_days(grant)
    grant.half_days - used_half_days(grant)
  end

  def used_half_days(grant)
    @used[grant_key(grant)]
  end

  def remaining_days(grant)
    self.class.days(remaining_half_days(grant))
  end

  def used_days(grant)
    self.class.days(used_half_days(grant))
  end

  # 有効期限が切れて失効した日数（期限切れの付与の、使われなかった残り）
  def lapsed_days(grant)
    grant.expired_on?(today) ? remaining_days(grant) : 0r
  end

  # 付与の状態：:active（有効）/ :expired（期限切れ）/ :future（付与日が未来）
  def grant_state(grant)
    if grant.expired_on?(today) then :expired
    elsif grant.future_on?(today) then :future
    else :active
    end
  end

  # 休暇の消化の内訳
  def usage_for(leave)
    @usages.find { |usage| usage.leave.equal?(leave) || (leave.id && usage.leave.id == leave.id) }
  end

  def usages
    @usages
  end

  # 有効な付与のうち、残りがあって一番早く失効するもの（[有効期限, 残日数]）。無ければ nil
  def next_expiry
    grant = grants.select { |item| item.usable_on?(today) && remaining_half_days(item).positive? }.min_by(&:expires_on)
    grant && [ grant.expires_on, remaining_days(grant) ]
  end

  private

  def grant_key(grant)
    grant.object_id
  end

  def allocate
    @used = Hash.new(0)
    @usages = leaves.map do |leave|
      allocations = Hash.new(0)
      uncovered = 0
      per_date = self.class.half_days_per_date(leave)
      leave.working_dates.each do |date|
        needed = per_date
        grants.each do |grant|
          break if needed.zero?
          next unless grant.usable_on?(date)

          take = [ grant.half_days - @used[grant_key(grant)], needed ].min
          next unless take.positive?

          @used[grant_key(grant)] += take
          allocations[grant] += take
          needed -= take
        end
        uncovered += needed
      end
      Usage.new(leave: leave, allocations: allocations.map { |grant, half_days| Allocation.new(grant: grant, half_days: half_days) },
                uncovered_half_days: uncovered)
    end
  end
end
