# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/obligations'
require 'io/providers_loader'
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

  # Пороги daily_turnover_min/max — реальные числа снапшота
  # data/providers.json (payflow.daily_turnover_min =
  # 2_000_000, vipay.daily_turnover_max = 5_000_000, дословно из ТЗ). Наблюдаемый
  # оборот (daily_approved_amount) переопределяется на сценарий: снапшот один
  # на все прогоны дня, а "недобрал"/"перебрал" — это разные моменты дня.
  # rubocop:disable-next RSpec/MultipleMemoizedHelpers -- snapshot/payflow/vipay
  # образуют один сценарий: пороги реальные, оборот переопределён под сценарий.
  describe 'на порогах боевого снапшота data/providers.json' do
    let(:snapshot_providers) { Io::ProvidersLoader.load('data/providers.json') }
    let(:snapshot_payflow) { snapshot_providers.find { |p| p.name == 'payflow' } }
    let(:snapshot_vipay) { snapshot_providers.find { |p| p.name == 'vipay' } }
    let(:payflow) { snapshot_payflow.with(daily_approved_amount: 500_000) }
    let(:vipay) { snapshot_vipay }

    # rubocop:disable-next RSpec/MultipleExpectations -- порог и
    # ранжирование проверяются вместе, числа из снапшота не выдуманы.
    it 'payflow, не набравший daily_turnover_min, стоит выше vipay' do
      expect(snapshot_payflow.daily_turnover_min).to eq(2_000_000)
      expect(payflow.daily_approved_amount).to be < payflow.daily_turnover_min

      ranked = strategy.rank([vipay, payflow], operation, state)

      expect(ranked.first.name).to eq('payflow')
    end

    # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- порог 90% и
    # ранжирование проверяются вместе, числа из снапшота не выдуманы.
    it 'vipay, перешагнувший 90% от daily_turnover_max, стоит ниже payflow' do
      near_max_vipay = snapshot_vipay.with(daily_approved_amount: 4_800_000)
      turnover = near_max_vipay.daily_approved_amount
      threshold = near_max_vipay.daily_turnover_max

      expect(near_max_vipay.daily_turnover_max).to eq(5_000_000)
      expect(turnover * 10 >= threshold * 9).to be(true)

      ranked = strategy.rank([near_max_vipay, payflow], operation, state)

      expect(ranked.map(&:name)).to eq(%w[payflow vipay])
    end

    it 'explain называет числа оборота, а не общие слова' do
      text = strategy.explain([payflow, vipay], operation, state)

      expect(text).to include('payflow').and match(/\d/)
    end
  end
end
