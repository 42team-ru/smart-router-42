# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/conversion'
require_relative '../../support/provider_factory'
require_relative '../../support/shared/strategy_contract'

RSpec.describe Routing::Strategies::Conversion do
  include ProviderFactory

  subject(:strategy) do
    described_class.new(observed: { 'vipay' => 0.780, 'payflow' => 0.474, 'quickpay' => 0.675 })
  end

  let(:candidates) do
    [build_provider(payment_system: 'vipay', conversion_24h: 0.87),
     build_provider(payment_system: 'payflow', conversion_24h: 0.91),
     build_provider(payment_system: 'quickpay', conversion_24h: 0.79)]
  end
  let(:operation) { build_operation }
  let(:state) { Routing::ShareLedger.new }

  it_behaves_like 'контракт стратегии'

  it 'упорядочивает по НАБЛЮДАЕМОЙ конверсии, а не по паспортной conversion_24h' do
    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.map(&:name)).to eq(%w[vipay quickpay payflow])
  end

  it 'payflow уезжает вниз при наблюдаемой конверсии 0.474' do
    ranked = strategy.rank(candidates, operation, state)

    expect(ranked.last.name).to eq('payflow')
  end

  it 'провайдер без истории уезжает в конец без исключения' do
    unknown = build_provider(payment_system: 'newpay')
    ranked = strategy.rank(candidates + [unknown], operation, state)

    expect(ranked.last.name).to eq('newpay')
  end

  describe 'без данных истории' do
    subject(:strategy) { described_class.new }

    # Файл стратегия не открывает: диска касается только bin/route. Без данных
    # она обязана выродиться предсказуемо, а не притащить их сама.
    it 'не падает и упорядочивает по имени' do
      ranked = strategy.rank(candidates, operation, state)

      expect(ranked.map(&:name)).to eq(candidates.map(&:name).sort)
    end
  end

  describe '.from_config' do
    # Конфиг стратегии не нужен вовсе — данные приходят отдельным аргументом.
    # nil здесь и есть утверждение: от содержимого конфига она не зависит.
    let(:config) { nil }

    it 'берёт конверсии из переданной истории, а не из конфига' do
      strategy = described_class.from_config(
        config, history: { 'vipay' => 0.78, 'payflow' => 0.474, 'quickpay' => 0.675 }
      )

      expect(strategy.rank(candidates, operation, state).map(&:name))
        .to eq(%w[vipay quickpay payflow])
    end

    it 'без истории вырождается вместо чтения файла' do
      strategy = described_class.from_config(config, history: nil)

      expect(strategy.rank(candidates, operation, state).map(&:name))
        .to eq(candidates.map(&:name).sort)
    end
  end
end
