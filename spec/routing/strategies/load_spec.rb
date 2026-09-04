# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/load'
require_relative '../../support/provider_factory'
require_relative '../../support/shared/strategy_contract'

RSpec.describe Routing::Strategies::Load do
  include ProviderFactory

  subject(:strategy) { described_class.new }

  let(:candidates) do
    [build_provider(payment_system: 'vipay', in_progress_count: 4, in_progress_count_limit: 10),
     build_provider(payment_system: 'payflow', in_progress_count: 2, in_progress_count_limit: 8),
     build_provider(payment_system: 'quickpay', in_progress_count: 1, in_progress_count_limit: 15)]
  end
  let(:operation) { build_operation }
  let(:state) { Routing::ShareLedger.new }

  it_behaves_like 'контракт стратегии'

  it 'ставит quickpay первым при наименьшей загрузке 1/15' do
    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.first.name).to eq('quickpay')
  end

  it 'упорядочивает по возрастанию in_progress_count / in_progress_count_limit' do
    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.map(&:name)).to eq(%w[quickpay payflow vipay])
  end

  it 'трактует отсутствие лимита как отсутствие нагрузки' do
    unlimited = build_provider(payment_system: 'spacepayments', in_progress_count: 100,
                               in_progress_count_limit: nil)
    ranked = strategy.rank([unlimited] + candidates, operation, state)

    expect(ranked.first.name).to eq('spacepayments')
  end
end
