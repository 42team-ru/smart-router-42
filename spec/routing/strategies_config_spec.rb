# frozen_string_literal: true

require 'config/routing_config'
require 'routing/share_ledger'
require 'routing/strategies'
require 'routing/strategies/amount_range'
require 'routing/strategies/conversion'
require 'routing/strategies/count_share'
require 'routing/strategies/load'
require 'routing/strategies/obligations'
require 'routing/strategies/priority'
require 'routing/strategies/volume_share'
require_relative '../support/provider_factory'

RSpec.describe Routing::Strategies do
  include ProviderFactory

  # Полный набор ключей Config::RoutingConfig: Data требует все десять.
  def config(strategy: 'count_share', amount_ranges: [], layers: [])
    Config::RoutingConfig.new(
      strategy: strategy, layers: layers, goals: {}, strategy_selection: {}, outcomes: {},
      amount_ranges: amount_ranges, obligations: {}, rate_limits: {},
      fallback_provider: 'spacepayments'
    )
  end

  let(:candidates) do
    [build_provider(payment_system: 'vipay', priority: 1),
     build_provider(payment_system: 'payflow', priority: 2),
     build_provider(payment_system: 'quickpay', priority: 3)]
  end
  let(:operation) { build_operation(amount: 15_000) }
  let(:state) { Routing::ShareLedger.new }
  let(:payflow_band) { [{ 'from' => 500, 'to' => 50_000, 'prefer' => 'payflow' }] }

  it 'без конфига строит amount_range с пустыми полосами — порядок по priority' do
    ranked = described_class.build('amount_range').rank(candidates, operation, state)

    expect(ranked.map(&:name)).to eq(%w[vipay payflow quickpay])
  end

  it 'с конфигом доставляет полосы в amount_range через from_config' do
    strategy = described_class.build('amount_range', config: config(amount_ranges: payflow_band))

    expect(strategy.rank(candidates, operation, state).first.name).to eq('payflow')
  end

  it 'классу без from_config конфиг не мешает' do
    expect(described_class.build('priority', config: config)).to be_a(Routing::Strategies::Priority)
  end

  it 'на неизвестное имя бросает KeyError с перечнем известных' do
    expect { described_class.build('нет_такой', config: config) }
      .to raise_error(KeyError, /нет_такой.*count_share/m)
  end

  it 'amount_range не хранит путь к конфигу: файлы читает только пайплайн' do
    expect(Routing::Strategies::AmountRange.const_defined?(:CONFIG_PATH)).to be(false)
  end

  it 'все семь стратегий строятся с конфигом' do
    built = described_class.known.map { |name| described_class.build(name, config: config) }

    expect(built.map(&:name)).to eq(described_class.known)
  end

  it 'все семь стратегий строятся и без конфига (контракт shared-спека)' do
    built = described_class.known.map { |name| described_class.build(name) }

    expect(built.map(&:name)).to eq(described_class.known)
  end
end
