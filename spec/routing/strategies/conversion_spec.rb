# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/conversion'
require 'io/history_stats'
require_relative '../../support/provider_factory'
require_relative '../../support/shared/strategy_contract'

RSpec.describe Routing::Strategies::Conversion do
  include ProviderFactory

  # history — Io::HistoryStats, а не голый Hash{имя => Float}: approved_bp уже
  # в базисных пунктах, n/approved_count нужны только для explain.
  def history_stats(bp_by_provider, k_value: 0, smoothed: false)
    entries = bp_by_provider.to_h do |name, attrs|
      [name, Io::HistoryStats::Entry.new(
        n: attrs.fetch(:n, 100), approved_count: attrs.fetch(:approved_count, 0),
        rejected_count: 0, expired_count: 0,
        approved_bp: attrs.fetch(:approved_bp), rejected_bp: 0, expired_bp: 0
      )]
    end
    Io::HistoryStats.new(entries: entries, k: k_value, smoothed: smoothed)
  end

  subject(:strategy) do
    described_class.new(history: history_stats(
      { 'vipay' => { approved_bp: 7800, n: 41, approved_count: 32 },
        'payflow' => { approved_bp: 4740, n: 19, approved_count: 9 },
        'quickpay' => { approved_bp: 6750, n: 40, approved_count: 27 } }
    ))
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

  it 'payflow уезжает вниз при наблюдаемой конверсии ниже конкурентов' do
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

  describe '#explain' do
    it 'показывает размер выборки и k у победителя, но не повторяет k у второго' do
      ranked = strategy.rank(candidates, operation, state)

      text = strategy.explain(ranked, operation, state)

      expect(text).to eq('conversion: vipay 780‰ (32/41) против quickpay 675‰ (27/40)')
    end

    # rubocop:disable-next RSpec/ExampleLength -- построение истории и проверка текста связаны одним сценарием.
    it 'помечает сглаживание, когда история сглажена' do
      smoothed_strategy = described_class.new(history: history_stats(
        { 'vipay' => { approved_bp: 7586, n: 41, approved_count: 32 },
          'payflow' => { approved_bp: 5510, n: 19, approved_count: 9 } },
        k_value: Rational(4_855_626_093, 426_317_971), smoothed: true
      ))
      ranked = smoothed_strategy.rank(candidates, operation, state)

      text = smoothed_strategy.explain(ranked, operation, state)
      expected = 'conversion: vipay 759‰ (32/41, сглажено k=11.4) против payflow 551‰ (9/19)'

      expect(text).to eq(expected)
    end
  end

  describe '.from_config' do
    # Конфиг стратегии не нужен вовсе — данные приходят отдельным аргументом.
    # nil здесь и есть утверждение: от содержимого конфига она не зависит.
    let(:config) { nil }

    # rubocop:disable-next RSpec/ExampleLength -- построение истории и проверка порядка связаны одним сценарием.
    it 'берёт конверсии из переданной истории, а не из конфига' do
      strategy = described_class.from_config(
        config, history: history_stats(
          { 'vipay' => { approved_bp: 7800 }, 'payflow' => { approved_bp: 4740 },
            'quickpay' => { approved_bp: 6750 } }
        )
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
