# frozen_string_literal: true

require 'routing/reasons'
require 'routing/violation'
require 'routing/route_plan'
require 'state/providers'
require 'execution/executor'
require 'execution/outcome_source/always_ok'
require 'execution/outcome_source/always_fail'
require 'execution/outcome_source/scripted'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers -- каждый
# сценарий каскада — набор связанных утверждений об одном прогоне (state после,
# состав attempts, selected). Именованные let-провайдеры (vipay/payflow/quickpay/
# spacepayments) — самое читаемое, чем вводить безымянный массив.
RSpec.describe Execution::Executor do
  let(:vipay) do
    build_provider('vipay', traffic_percentage: 40, banks: %w[sberbank],
                            limit_amount_min: 1000, limit_amount_max: 100_000,
                            available_requisites: 12, merchant_margin_pct: 1.5,
                            provider_margin_pct: 1.2)
  end
  let(:payflow) do
    build_provider('payflow', traffic_percentage: 35, banks: %w[sberbank],
                              limit_amount_min: 500, limit_amount_max: 50_000,
                              available_requisites: 5, merchant_margin_pct: 1.5,
                              provider_margin_pct: 1.0)
  end
  let(:quickpay) do
    build_provider('quickpay', traffic_percentage: 25, banks: [],
                               limit_amount_min: 1000, limit_amount_max: 200_000,
                               available_requisites: 20, merchant_margin_pct: 1.5,
                               provider_margin_pct: 0.8)
  end
  let(:spacepayments) do
    build_spacepayments(traffic_percentage: 0, merchant_margin_pct: 1.5,
                        provider_margin_pct: 0.5)
  end
  let(:providers) { [vipay, payflow, quickpay, spacepayments] }
  let(:operation) { build_operation(id: 'op_1', amount: 10_000, bank: 'sberbank') }
  let(:operation_hash) { { 'operation_id' => 'op_1', 'amount' => 10_000, 'bank' => 'sberbank' } }
  let(:providers_snapshot_hash) do
    providers.map do |p|
      p.to_h.transform_keys(&:to_s).merge('payment_system' => p.name)
    end
  end

  let(:state) { State::Providers.new(providers) }
  let(:initial_snapshot) do
    providers.to_h do |p|
      [p.name,
       { in_progress_count: p.in_progress_count.to_i,
         in_progress_amount: p.in_progress_amount.to_i,
         daily_approved_amount: p.daily_approved_amount.to_i }]
    end
  end

  # Каждый сценарий определяет executor, plan; общие let для скрытых сущностей
  # (state_after, outcome, run_twice) — здесь, чтобы shared_examples 'state
  # invariants' работал без копипасты.
  let(:state_after) { outcome && state }
  let(:outcome) { executor.run(plan, operation, state) }
  let(:run_twice) do
    lambda do
      [1, 2].map do
        fresh_state = State::Providers.new(providers)
        executor.run(plan, operation, fresh_state)
      end
    end
  end

  def script_source(script)
    Execution::OutcomeSource::Scripted.new(script: script)
  end

  describe 'сценарий 1: первый успешен' do
    let(:executor) { described_class.new(outcomes: Execution::OutcomeSource::AlwaysOk.new) }
    let(:plan) do
      Routing::RoutePlan.new(operation: operation, candidates: [vipay], skipped: [])
    end

    it 'одна selected-попытка, daily_approved вырос только у победителя' do
      expect(outcome.result).to eq(:approved)
      expect(outcome.selected.name).to eq('vipay')
      expect(outcome.attempts.size).to eq(1)
      expect(outcome.attempts.first.reason).to eq('only_eligible_provider')
      expect(outcome.attempts.first.result).to eq('approved')
      expect(state_after.daily_approved_amount('vipay')).to eq(10_000)
    end

    it_behaves_like 'state invariants'
  end

  describe 'сценарий 2: отказ → следующий успешен' do
    let(:executor) do
      described_class.new(outcomes: script_source(
        'op_1' => { 'vipay' => :rejected, 'payflow' => :approved }
      ))
    end
    let(:plan) do
      Routing::RoutePlan.new(operation: operation, candidates: [vipay, payflow], skipped: [])
    end

    it 'две selected-попытки, rollback у первого, commit у второго' do
      expect(outcome.result).to eq(:approved)
      expect(outcome.selected.name).to eq('payflow')
      expect(outcome.attempts.map { |a| [a.provider.name, a.result] })
        .to eq([%w[vipay rejected], %w[payflow approved]])
      expect(outcome.attempts[1].reason).to eq('next_in_cascade')
      expect(state_after.daily_approved_amount('vipay')).to eq(0)
      expect(state_after.daily_approved_amount('payflow')).to eq(10_000)
    end

    it_behaves_like 'state invariants'
  end

  describe 'сценарий 3: таймаут (:expired)' do
    let(:executor) do
      described_class.new(outcomes: script_source('op_1' => { 'vipay' => :expired }))
    end
    let(:plan) do
      Routing::RoutePlan.new(operation: operation, candidates: [vipay, payflow], skipped: [])
    end

    it 'одна selected-попытка, in_progress держится, daily_approved не тронут' do
      expect(outcome.result).to eq(:expired)
      expect(outcome.selected.name).to eq('vipay')
      expect(outcome.attempts.size).to eq(1)
      expect(outcome.attempts.first.result).to eq('expired')
      expect(state_after.in_progress_count('vipay')).to eq(1)
      expect(state_after.daily_approved_amount('vipay')).to eq(0)
    end

    it_behaves_like 'state invariants'
  end

  describe 'сценарий 4: каскад исчерпан' do
    let(:executor) { described_class.new(outcomes: Execution::OutcomeSource::AlwaysFail.new) }
    let(:plan) do
      Routing::RoutePlan.new(operation: operation, candidates: [vipay, payflow, quickpay],
                             skipped: [])
    end

    it 'selected = последний реальный, spacepayments НЕ в attempts' do
      expect(outcome.result).to eq(:rejected)
      expect(outcome.selected.name).to eq('quickpay')
      expect(outcome.attempts.map { |a| a.provider.name }).to eq(%w[vipay payflow quickpay])
      expect(outcome.attempts.map(&:result)).to all(eq('rejected'))
    end

    it_behaves_like 'state invariants'
  end

  describe 'сценарий 5: пустой план — fallback по допуску' do
    let(:violation) { Routing::Violation.new(reason: 'bank_not_in_list', details: 'x') }
    let(:executor) { described_class.new(outcomes: Execution::OutcomeSource::AlwaysOk.new) }
    let(:plan) do
      Routing::RoutePlan.new(
        operation: operation, candidates: [],
        skipped: [[vipay, violation], [payflow, violation], [quickpay, violation]]
      )
    end

    it 'selected = spacepayments, reason fallback_no_eligible_provider, skipped идут первыми' do
      expect(outcome.selected.name).to eq('spacepayments')
      expect(outcome.attempts.size).to eq(4)
      expect(outcome.attempts.first(3).map(&:decision)).to all(eq('skipped'))
      expect(outcome.attempts.last.reason).to eq('fallback_no_eligible_provider')
      expect(outcome.attempts.last.details).to eq('допустимых внешних провайдеров 0 из 3')
      expect(outcome.attempts.last.attempt_no).to eq(1)
    end

    it_behaves_like 'state invariants'
  end

  describe 'skipped из плана идут первыми в attempts' do
    let(:violation) { Routing::Violation.new(reason: 'amount_exceeds_limit', details: 'x') }
    let(:executor) { described_class.new(outcomes: Execution::OutcomeSource::AlwaysOk.new) }
    let(:plan) do
      Routing::RoutePlan.new(operation: operation, candidates: [payflow],
                             skipped: [[vipay, violation]])
    end

    it 'сохраняет порядок plan.skipped, потом selected по каскаду' do
      expect(outcome.attempts.map(&:decision)).to eq(%w[skipped selected])
      expect(outcome.attempts.map { |a| a.provider.name }).to eq(%w[vipay payflow])
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
