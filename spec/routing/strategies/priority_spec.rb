# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/priority'
require_relative '../../support/provider_factory'
require_relative '../../support/shared/strategy_contract'

RSpec.describe Routing::Strategies::Priority do
  include ProviderFactory

  subject(:strategy) { described_class.new }

  let(:candidates) do
    [build_provider(payment_system: 'quickpay', priority: 3),
     build_provider(payment_system: 'vipay', priority: 1),
     build_provider(payment_system: 'payflow', priority: 2)]
  end
  let(:operation) { build_operation }
  let(:state) { Routing::ShareLedger.new }

  it_behaves_like 'контракт стратегии'

  it 'упорядочивает по возрастанию priority: vipay → payflow → quickpay' do
    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.map(&:name)).to eq(%w[vipay payflow quickpay])
  end
end
