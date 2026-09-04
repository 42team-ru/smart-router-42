# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/obligations'
require_relative '../../support/provider_factory'
require_relative '../../support/shared/strategy_contract'

RSpec.describe Routing::Strategies::Obligations do
  include ProviderFactory

  subject(:strategy) { described_class.new }

  let(:candidates) do
    [build_provider(payment_system: 'vipay'),
     build_provider(payment_system: 'payflow', daily_turnover_min: 2_000_000,
                    daily_approved_amount: 1_000_000),
     build_provider(payment_system: 'quickpay')]
  end
  let(:operation) { build_operation }
  let(:state) { Routing::ShareLedger.new }
  # Имя apay нарочно раньше 'payflow' по алфавиту, чтобы финальный tie-break
  # по имени не маскировал переход payflow из tier 0 в tier 1.
  let(:payflow_near_min) do
    build_provider(payment_system: 'payflow', daily_turnover_min: 2_000_000,
                   daily_approved_amount: 1_900_000)
  end
  let(:apay) { build_provider(payment_system: 'apay') }

  it_behaves_like 'контракт стратегии'

  it 'недобравший daily_turnover_min поднимается наверх' do
    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.first.name).to eq('payflow')
  end

  it 'провайдер без обязательств не двигается относительно других без обязательств' do
    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.map(&:name).last(2)).to match_array(%w[vipay quickpay])
  end

  it 'близкий к daily_turnover_max (≥90%) опускается ниже провайдера без обязательств' do
    near_max = build_provider(payment_system: 'payflow', daily_turnover_max: 5_000_000,
                              daily_approved_amount: 4_800_000)
    no_obligations = build_provider(payment_system: 'vipay')

    ranked = strategy.rank([near_max, no_obligations], operation, state)

    expect(ranked.map(&:name)).to eq(%w[vipay payflow])
  end

  it 'без резерва в этом прогоне payflow ещё не набрал минимум и поднят наверх' do
    ranked = strategy.rank([payflow_near_min, apay], operation, Routing::ShareLedger.new)

    expect(ranked.first.name).to eq('payflow')
  end

  it 'с резервом в этом прогоне payflow набирает минимум и перестаёт подниматься' do
    ledger = Routing::ShareLedger.new
    ledger.reserve(payflow_near_min, build_operation(operation_id: 'op_x', amount: 200_000))

    ranked = strategy.rank([payflow_near_min, apay], operation, ledger)

    expect(ranked.first.name).to eq('apay')
  end
end
