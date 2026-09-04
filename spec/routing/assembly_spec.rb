# frozen_string_literal: true

require 'config/routing_config'
require 'routing/assembly'
require 'routing/layers'
require 'routing/share_ledger'
require 'routing/strategies/amount_range'
require 'routing/strategies/conversion'
require 'routing/strategies/count_share'
require 'routing/strategies/load'
require 'routing/strategies/obligations'
require 'routing/strategies/priority'
require 'routing/strategies/volume_share'
require_relative '../support/provider_factory'

RSpec.describe Routing::Assembly do
  include ProviderFactory

  def cfg(strategy: 'count_share', layers: [], amount_ranges: [])
    Config::RoutingConfig.new(
      strategy: strategy, layers: layers, goals: {}, strategy_selection: {},
      allocator: {}, outcomes: {},
      amount_ranges: amount_ranges, obligations: {}, rate_limits: {},
      fallback_provider: 'spacepayments'
    )
  end

  let(:candidates) do
    [build_provider(payment_system: 'vipay', priority: 1),
     build_provider(payment_system: 'payflow', priority: 2),
     build_provider(payment_system: 'quickpay', priority: 3)]
  end
  let(:state) { Routing::ShareLedger.new }

  describe '.strategy' do
    it 'берёт имя из конфига, когда переопределения нет' do
      expect(described_class.strategy(config: cfg(strategy: 'load')))
        .to be_a(Routing::Strategies::Load)
    end

    it 'CLI перекрывает YAML' do
      strategy = described_class.strategy(config: cfg(strategy: 'load'), override: 'priority')

      expect(strategy).to be_a(Routing::Strategies::Priority)
    end

    it 'override: nil переопределением не считается' do
      strategy = described_class.strategy(config: cfg(strategy: 'load'), override: nil)

      expect(strategy).to be_a(Routing::Strategies::Load)
    end

    it 'пустая строка в override переопределением не считается' do
      strategy = described_class.strategy(config: cfg(strategy: 'load'), override: '')

      expect(strategy).to be_a(Routing::Strategies::Load)
    end

    it 'доставляет данные конфига в стратегию, а не только имя класса' do
      bands = [{ 'from' => 500, 'to' => 50_000, 'prefer' => 'payflow' }]
      strategy = described_class.strategy(config: cfg(strategy: 'amount_range',
                                                      amount_ranges: bands))
      ranked = strategy.rank(candidates, build_operation(amount: 15_000), state)

      expect(ranked.first.name).to eq('payflow')
    end

    it 'на опечатку в YAML называет источником конфиг' do
      expect { described_class.strategy(config: cfg(strategy: 'нет_такой')) }
        .to raise_error(KeyError, %r{config/routing\.yml.*count_share}m)
    end

    it 'на опечатку во флаге называет источником --strategy' do
      expect { described_class.strategy(config: cfg(strategy: 'load'), override: 'нет_такой') }
        .to raise_error(KeyError, /--strategy.*count_share/m)
    end

    it 'конфиг не мутирует' do
      config = cfg(strategy: 'load')

      described_class.strategy(config: config, override: 'priority')

      expect(config).to eq(cfg(strategy: 'load'))
    end
  end

  describe '.layers' do
    it 'на пустой список отдаёт пустой список' do
      expect(described_class.layers(config: cfg(layers: []))).to eq([])
    end

    it 'непустой список роняет сборку, а не игнорируется молча' do
      expect { described_class.layers(config: cfg(layers: ['conversion'])) }
        .to raise_error(KeyError, /conversion.*Ф4/m)
    end
  end

  describe Routing::Layers do
    it 'реестр слоёв пуст' do
      expect(described_class.known).to eq([])
    end

    it 'не подхватывает одноимённую стратегию: реестры раздельные' do
      expect { described_class.build('conversion') }.to raise_error(KeyError, /unknown layer/)
    end

    it 'автозагрузка каталога слоёв явно сортирует Dir' do
      source = File.read(File.expand_path('../../lib/routing/layers.rb', __dir__))

      expect(source).to include("Dir[File.expand_path('layers/*.rb', __dir__)].sort")
    end
  end
end
