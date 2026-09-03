# frozen_string_literal: true

require 'json'
require 'routing/reasons'

# Инварианты §15 ARCH, которые обязаны держаться на каждом прогоне
# Executor+State — а не проверяться отдельным сценарием. Подключаются в
# любой спек одной строкой:
#
#   include_examples 'state invariants'
#
# Спек-контекст должен определить:
#   let(:initial_snapshot)         Hash{name => {in_progress_count:, in_progress_amount:,
#                                                 daily_approved_amount:}}
#   let(:outcome)                  Execution::Outcome после прогона
#   let(:state_after)              State::Providers после прогона
#   let(:operation_hash)           Hash с полями operation_id, amount, bank
#                                  (для проверки правилами валидатора)
#   let(:providers_snapshot_hash)  Array<Hash> — исходный providers.json как есть
#                                  (снимок ДО списаний, требование инварианта #4)
#   let(:run_twice)                Proc, возвращает [outcome1, outcome2] от двух
#                                  fresh-прогонов на одинаковом входе
#
# Инвариант #4 использует свою реализацию eligible_providers, а не наш
# Constraints::REGISTRY — иначе разъезд с валидатором организаторов не
# обнаружится (замкнётся сам на себя).
module SharedStateInvariants
  # Логика взята из reference/scripts/validate_10.rb:25-51 — переписана здесь,
  # чтобы менять её приходилось одновременно с валидатором организаторов.
  def self.eligible_providers(operation, providers)
    amount = operation.fetch('amount')
    bank = operation.fetch('bank')

    eligible = providers.select { |p| eligible_by_hard_rules?(p, amount, bank) }
    eligible.map { |p| p.fetch('payment_system') }
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength -- дословный перепис
  # reference/scripts/validate_10.rb; фрагментация уведёт от эталона.
  def self.eligible_by_hard_rules?(provider, amount, bank)
    return false if provider['status'] != 'active'
    if provider['traffic_percentage'].to_f.zero? && provider['payment_system'] != 'spacepayments'
      return false
    end
    return false if provider['limit_amount_min'] && amount < provider['limit_amount_min']
    return false if provider['limit_amount_max'] && amount > provider['limit_amount_max']
    if provider['daily_amount_limit'] &&
       (provider['daily_approved_amount'].to_f + amount) > provider['daily_amount_limit']
      return false
    end
    if provider['in_progress_count_limit'] &&
       (provider['in_progress_count'].to_i + 1) > provider['in_progress_count_limit']
      return false
    end
    if provider['in_progress_amount_limit'] &&
       (provider['in_progress_amount'].to_f + amount) > provider['in_progress_amount_limit']
      return false
    end
    return false if provider['available_requisites'].to_i.zero?
    if provider['provider_margin_pct'].to_f > provider['merchant_margin_pct'].to_f &&
       !provider['allow_negative_agreement']
      return false
    end

    banks = provider['banks'] || []
    return true if banks.empty?

    if provider['exclude_banks']
      !banks.include?(bank)
    else
      banks.include?(bank)
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
end

# связанных утверждений об одном прогоне; дробить по одному это на провайдера
# бессмысленно.
RSpec.shared_examples 'state invariants' do
  it '#1 в attempts нет дублей провайдеров' do
    names = outcome.attempts.map { |a| a.provider.name }

    expect(names.uniq.size).to eq(names.size)
  end

  # rubocop:disable-next RSpec/ExampleLength -- per-provider проход + логика expired-winner
  it '#2 in_progress возвращён к исходному для всех провайдеров, кроме expired-winner' do
    winner = outcome.selected&.name
    held_by_expired = outcome.result == :expired ? winner : nil

    initial_snapshot.each do |name, snap|
      next if name == held_by_expired

      expect(state_after.in_progress_count(name))
        .to eq(snap.fetch(:in_progress_count)),
            "in_progress_count(#{name}) не восстановлен"
    end
  end

  it '#3 все skipped-причины входят в Routing::Reasons::SKIP' do
    reasons = outcome.attempts.select { |a| a.decision == 'skipped' }.map(&:reason)

    reasons.each do |r|
      expect(Routing::Reasons::SKIP).to include(r)
    end
  end

  it '#4 selected_provider входит в eligible_providers по правилам валидатора' do
    eligible = SharedStateInvariants.eligible_providers(operation_hash, providers_snapshot_hash)

    expect(eligible).to include(outcome.selected.name)
  end

  it '#5 два прогона одного входа дают побайтово одинаковый Outcome' do
    json = run_twice.call.map { |o| SharedStateInvariants.outcome_to_json(o) }

    expect(json.uniq.size).to eq(1)
  end
end

module SharedStateInvariants
  def self.outcome_to_json(outcome)
    JSON.generate(
      selected: outcome.selected.name,
      result: outcome.result.to_s,
      attempts: outcome.attempts.map do |a|
        a.to_h.transform_values { |v| v.respond_to?(:name) ? v.name : v }
      end
    )
  end
end
