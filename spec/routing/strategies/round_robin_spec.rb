# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/round_robin'
require_relative '../../support/provider_factory'
require_relative '../../support/shared/strategy_contract'

RSpec.describe Routing::Strategies::RoundRobin do
  include ProviderFactory

  subject(:strategy) { described_class.new }

  let(:candidates) do
    [build_provider(payment_system: 'vipay'),
     build_provider(payment_system: 'payflow'),
     build_provider(payment_system: 'quickpay')]
  end
  let(:operation) { build_operation }
  let(:state) { Routing::ShareLedger.new }

  it_behaves_like 'контракт стратегии'

  # base отсортирован по имени: payflow, quickpay, vipay.
  it 'ротирует отсортированный по имени базовый порядок на state.total_count_units по модулю' do
    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.map(&:name)).to eq(%w[payflow quickpay vipay])
  end

  it 'смещение зависит только от state.total_count_units, а не от порядка входа' do
    provider = build_provider(payment_system: 'vipay')
    state.reserve(provider, build_operation(operation_id: 'op_a'))
    state.reserve(provider, build_operation(operation_id: 'op_b'))

    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.map(&:name)).to eq(%w[vipay payflow quickpay])
  end

  it 'два экземпляра стратегии при одинаковом состоянии дают одинаковый порядок' do
    other = described_class.new
    provider = build_provider(payment_system: 'payflow')
    state.reserve(provider, build_operation(operation_id: 'op_c'))

    expect(other.rank(candidates, operation,
                      state)).to eq(strategy.rank(candidates, operation, state))
  end

  it 'один экземпляр, вызванный дважды подряд при неизменном состоянии, даёт одинаковый порядок' do
    first_call = strategy.rank(candidates, operation, state)
    second_call = strategy.rank(candidates, operation, state)

    expect(second_call).to eq(first_call)
  end

  it 'не хранит счётчик внутри себя: смещение меняется только со сменой состояния' do
    provider = build_provider(payment_system: 'quickpay')
    before_reserve = strategy.rank(candidates, operation, state)
    state.reserve(provider, build_operation(operation_id: 'op_d'))
    after_reserve = strategy.rank(candidates, operation, state)

    expect(after_reserve).not_to eq(before_reserve)
  end

  it 'единственный кандидат -- вырожденный случай без деления на ноль' do
    solo = [candidates.first]

    expect(strategy.rank(solo, operation, state)).to eq(solo)
  end

  it 'explain содержит числа позиции и размера множества' do
    ranked = strategy.rank(candidates, operation, state)

    expect(strategy.explain(ranked, operation, state)).to match(/позиция \d+ из \d+/)
  end

  it 'explain для вырожденного случая одного кандидата не падает' do
    solo = [candidates.first]
    ranked = strategy.rank(solo, operation, state)

    expect(strategy.explain(ranked, operation, state)).to include('позиция 1 из 1')
  end
end
