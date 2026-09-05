# frozen_string_literal: true

require 'json'
require 'io/providers_loader'
require 'io/queue_loader'
require 'routing/planner'
require 'routing/strategies/count_share'
require 'state/providers'
require 'execution/executor'
require 'execution/outcome_source/always_ok'

# Лимиты интенсивности здесь -- НЕ значения из data/providers.json (7/10/15,
# см. P2_rate_limit.md, таблица "Значения"). На 10 операциях одной минуты и
# с четырьмя зарезервированными деталями кейсами эти лимиты в принципе
# недостижимы (ни один провайдер не может получить 7+ реальных резервов за
# 10 заявок, из которых 4 жёстко исключают его как минимум одного внешнего
# конкурента). Здесь свои маленькие лимиты -- specific-для-спека способ
# гарантированно упереться в оба сценария (реальный отсев и неприменение),
# не трогая production-значения и не подсовывая фиктивные суммы/банки.
module DenseMinuteReference
  TEST_LIMITS = { 'vipay' => 3, 'payflow' => 1, 'quickpay' => 15 }.freeze

  module_function

  def deterministic_cases
    JSON.parse(File.read(reference_path('reference_decisions.json'))).fetch('deterministic_cases')
  end

  # Копия eligible_providers из reference/scripts/validate_10.rb: то же самое
  # сравнение, буква в букву, на пристинных данных организаторов -- иначе
  # проверка "selected_provider допустим" сверяла бы наш допуск сама с собой.
  def eligible_providers(operation_hash, providers_hash)
    amount = operation_hash['amount']
    bank = operation_hash['bank']

    matched = providers_hash.select { |provider| eligible_provider?(provider, amount, bank) }
    matched.map { |provider| provider['payment_system'] }
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity
  # rubocop:disable-next Metrics/PerceivedComplexity
  def eligible_provider?(provider, amount, bank)
    return false if provider['status'] != 'active'
    return false if zero_traffic?(provider)
    return false if provider['limit_amount_min'] && amount < provider['limit_amount_min']
    return false if provider['limit_amount_max'] && amount > provider['limit_amount_max']
    return false if over_daily_limit?(provider, amount)
    return false if over_in_progress_count?(provider)
    return false if over_in_progress_amount?(provider, amount)
    return false if provider['available_requisites'].to_i.zero?
    return false if negative_margin?(provider)

    bank_allowed?(provider, bank)
  end

  def zero_traffic?(provider)
    provider['traffic_percentage'].to_f.zero? && provider['payment_system'] != 'spacepayments'
  end

  def over_daily_limit?(provider, amount)
    limit = provider['daily_amount_limit']
    limit && (provider['daily_approved_amount'].to_f + amount) > limit
  end

  def over_in_progress_count?(provider)
    limit = provider['in_progress_count_limit']
    limit && (provider['in_progress_count'].to_i + 1) > limit
  end

  def over_in_progress_amount?(provider, amount)
    limit = provider['in_progress_amount_limit']
    limit && (provider['in_progress_amount'].to_f + amount) > limit
  end

  def negative_margin?(provider)
    provider['provider_margin_pct'].to_f > provider['merchant_margin_pct'].to_f &&
      !provider['allow_negative_agreement']
  end

  def bank_allowed?(provider, bank)
    banks = provider['banks'] || []
    return true if banks.empty?
    return !banks.include?(bank) if provider['exclude_banks']

    banks.include?(bank)
  end
end

# "Интенсивность" ожила -- у RateLimit теперь есть и значение в снапшоте, и
# работающий счётчик. Этот спек гоняет
# полный пайплайн (Planner + State::Providers + Executor) на плотной очереди
# (spec/fixtures/queues/dense_minute.json -- 10 операций одной минуты, суммы и
# банки как в operations_queue_10.json) и проверяет три вещи разом: правило
# срабатывает по-настоящему (иначе оно снова мертво), правило неприменения
# тоже срабатывает хотя бы раз, и оба случая не выводят решение за пределы
# допустимого по ПРИСТИННОМУ снапшоту организаторов.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
# -- providers/operations/state/planner/executor/results образуют один пайплайн.
RSpec.describe 'rate limit в полном пайплайне (плотная минута)' do
  let(:pristine_raw) do
    JSON.parse(File.read(reference_path('providers.json'))).fetch('providers')
  end
  let(:pristine_providers) { Io::ProvidersLoader.load(reference_path('providers.json')) }
  let(:providers) do
    pristine_providers.map do |provider|
      provider.with(requests_per_minute_limit: DenseMinuteReference::TEST_LIMITS[provider.name])
    end
  end
  let(:queue_path) { fixture_path('queues', 'dense_minute.json') }
  let(:raw_operations) { JSON.parse(File.read(queue_path)) }
  let(:operations) { Io::QueueLoader.load(queue_path).operations }
  let(:state) { State::Providers.new(providers) }
  let(:planner) { Routing::Planner.new(providers: providers) }
  let(:executor) { Execution::Executor.new(outcomes: Execution::OutcomeSource::AlwaysOk.new) }

  let(:results) do
    operations.map do |operation|
      plan = planner.plan(operation, state)
      outcome = executor.run(plan, operation, state)
      { operation: operation, plan: plan, outcome: outcome }
    end
  end

  def skip_reasons
    results.flat_map { |result| result.fetch(:outcome).attempts }
           .select { |attempt| attempt.decision == 'skipped' }
           .map(&:reason)
  end

  it 'ограничение по интенсивности реально отсеивает хотя бы одного кандидата' do
    expect(skip_reasons).to include('rate_limit_exceeded')
  end

  it 'правило неприменения срабатывает хотя бы раз и details содержит числа лимита' do
    notes = results.filter_map { |result| result.fetch(:plan).trace&.details }
                   .select { |details| details.include?('ограничение не применено') }

    expect(notes).not_to be_empty
    expect(notes).to all(match(/\d+.*\d+/))
  end

  it 'каждый selected_provider входит в множество допустимых по пристинному снапшоту' do
    results.each do |result|
      operation_hash = raw_operations.find do |raw|
        raw['operation_id'] == result.fetch(:operation).operation_id
      end
      eligible = DenseMinuteReference.eligible_providers(operation_hash, pristine_raw)
      selected_name = result.fetch(:outcome).selected.name
      message = "#{result.fetch(:operation).operation_id}: #{selected_name} не в #{eligible}"

      expect(eligible).to include(selected_name), message
    end
  end

  DenseMinuteReference.deterministic_cases.each do |case_|
    it "детерминированный кейс #{case_.fetch('operation_id')} даёт " \
       "#{case_.fetch('required_provider')}" do
      result = results.find do |item|
        item.fetch(:operation).operation_id == case_.fetch('operation_id')
      end

      expect(result.fetch(:outcome).selected.name).to eq(case_.fetch('required_provider'))
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
