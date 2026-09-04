# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/amount_range'
require_relative '../../support/provider_factory'
require_relative '../../support/shared/strategy_contract'

RSpec.describe Routing::Strategies::AmountRange do
  include ProviderFactory

  subject(:strategy) do
    described_class.new(ranges: [
                          { 'from' => 500, 'to' => 50_000, 'prefer' => 'payflow' },
                          { 'from' => 50_001, 'to' => 100_000, 'prefer' => 'vipay' },
                          { 'from' => 100_001, 'to' => nil, 'prefer' => 'quickpay' }
                        ])
  end

  let(:candidates) do
    [build_provider(payment_system: 'vipay', priority: 1),
     build_provider(payment_system: 'payflow', priority: 2),
     build_provider(payment_system: 'quickpay', priority: 3)]
  end
  let(:operation) { build_operation(amount: 15_000) }
  let(:state) { Routing::ShareLedger.new }

  it_behaves_like 'контракт стратегии'

  it 'ставит payflow первым на 15 000, хотя допущены все' do
    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.first.name).to eq('payflow')
  end

  it 'подчиняется полосе выше — vipay первым на 60 000' do
    ranked = strategy.rank(candidates, build_operation(amount: 60_000), state)

    expect(ranked.first.name).to eq('vipay')
  end

  it 'открытая верхняя полоса (to: nil) ставит quickpay первым на 150 000' do
    ranked = strategy.rank(candidates, build_operation(amount: 150_000), state)

    expect(ranked.first.name).to eq('quickpay')
  end

  it 'без совпавшей полосы падает обратно на priority, а не бросает исключение' do
    ranked = strategy.rank(candidates, build_operation(amount: 100), state)

    expect(ranked.map(&:name)).to eq(%w[vipay payflow quickpay])
  end
end
