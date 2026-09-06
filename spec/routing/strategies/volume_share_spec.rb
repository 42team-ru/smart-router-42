# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/volume_share'
require_relative '../../support/provider_factory'
require_relative '../../support/shared/strategy_contract'

RSpec.describe Routing::Strategies::VolumeShare do
  include ProviderFactory

  subject(:strategy) { described_class.new }

  let(:candidates) do
    [build_provider(payment_system: 'vipay', traffic_percentage: 40),
     build_provider(payment_system: 'payflow', traffic_percentage: 35),
     build_provider(payment_system: 'quickpay', traffic_percentage: 25)]
  end
  let(:operation) { build_operation }
  let(:state) { Routing::ShareLedger.new }

  it_behaves_like 'контракт стратегии'

  def seed(ledger, provider, operation_id, amount)
    seed_operation = build_operation(operation_id: operation_id, amount: amount)
    ledger.reserve(provider, seed_operation).commit(provider, seed_operation)
  end

  # Контрпример из брифа П2: старая версия (дефицит ДО заявки, без учёта её
  # размера) на этих числах ставит первым quickpay — 45/55 против целевых
  # 80/20, ошибка 70 п.п. Новая версия обязана поставить первым vipay:
  # 95/5 против целевых 80/20, ошибка 30 п.п. — вдвое меньше.
  describe 'учёт размера текущей заявки' do
    let(:vipay) { build_provider(payment_system: 'vipay', traffic_percentage: 80) }
    let(:quickpay) { build_provider(payment_system: 'quickpay', traffic_percentage: 20) }
    let(:candidates) { [vipay, quickpay] }
    let(:operation) { build_operation(amount: 100_000) }
    let(:state) do
      ledger = Routing::ShareLedger.new
      seed(ledger, vipay, 'op_seed_a', 90_000)
      seed(ledger, quickpay, 'op_seed_b', 10_000)
      ledger
    end

    it 'ставит первым провайдера с меньшей ошибкой ПОСЛЕ гипотетического назначения' do
      ranked = strategy.rank(candidates, operation, state)

      expect(ranked.map(&:name)).to eq(%w[vipay quickpay])
    end

    it 'explain фиксирует формат: ошибка в процентных пунктах с одним знаком после запятой' do
      ranked = strategy.rank(candidates, operation, state)

      expect(strategy.explain(ranked, operation, state)).to eq(
        'volume_share: vipay ошибка 30.0 п.п. против quickpay 70.0 п.п. ' \
        'при заявке 100000 (веса 8000/2000 bp)'
      )
    end

    it 'ранжирование не меняется от того, вызывался ли explain (деление — только на выводе)' do
      ranking_without_explain = strategy.rank(candidates, operation, state)
      strategy.explain(ranking_without_explain, operation, state)
      ranking_after_explain = strategy.rank(candidates, operation, state)

      expect(ranking_after_explain).to eq(ranking_without_explain)
    end

    it 'порядок после explain остаётся vipay, quickpay' do
      ranked = strategy.rank(candidates, operation, state)
      strategy.explain(ranked, operation, state)

      expect(strategy.rank(candidates, operation, state).map(&:name)).to eq(%w[vipay quickpay])
    end
  end

  describe 'вырожденный случай — один кандидат' do
    let(:candidates) { [build_provider(payment_system: 'vipay', traffic_percentage: 40)] }

    it 'возвращает единственного кандидата тем же объектом' do
      expect(strategy.rank(candidates, operation, state)).to eq(candidates)
    end

    it 'explain не падает на единственном кандидате' do
      ranked = strategy.rank(candidates, operation, state)

      expect(strategy.explain(ranked, operation, state)).to be_a(String).and match(/\d/)
    end
  end

  describe 'разрыв ничьей' do
    let(:candidates) do
      [build_provider(payment_system: 'quickpay', traffic_percentage: 30),
       build_provider(payment_system: 'payflow', traffic_percentage: 30)]
    end

    it 'при равном весе и равном (нулевом) объёме порядок определяется именем' do
      ranked = strategy.rank(candidates, operation, state)

      expect(ranked.map(&:name)).to eq(%w[payflow quickpay])
    end

    it 'стабилен между прогонами и не зависит от порядка на входе' do
      first_run = strategy.rank(candidates, operation, state)
      second_run = strategy.rank(candidates.reverse, operation, state)

      expect(second_run.map(&:name)).to eq(first_run.map(&:name))
    end
  end

  describe 'перестановка на 3+ кандидатах с непустой историей' do
    let(:candidates) do
      [build_provider(payment_system: 'vipay', traffic_percentage: 40),
       build_provider(payment_system: 'payflow', traffic_percentage: 35),
       build_provider(payment_system: 'quickpay', traffic_percentage: 25)]
    end
    let(:operation) { build_operation(amount: 20_000) }
    let(:state) do
      ledger = Routing::ShareLedger.new
      seed(ledger, candidates[0], 'op_seed_a', 40_000)
      seed(ledger, candidates[1], 'op_seed_b', 10_000)
      ledger
    end

    it 'возвращает перестановку входного списка той же длины' do
      expect(strategy.rank(candidates, operation, state).map(&:name))
        .to match_array(candidates.map(&:name))
    end
  end

  describe 'нулевой суммарный объём (первая заявка очереди)' do
    let(:candidates) do
      [build_provider(payment_system: 'vipay', traffic_percentage: 40),
       build_provider(payment_system: 'payflow', traffic_percentage: 35),
       build_provider(payment_system: 'quickpay', traffic_percentage: 25)]
    end
    let(:operation) { build_operation(amount: 15_000) }
    let(:state) { Routing::ShareLedger.new }

    it 'не падает и не делит на ноль при total_volume_units = 0' do
      expect { strategy.rank(candidates, operation, state) }.not_to raise_error
    end

    it 'отдаёт предпочтение провайдеру с наибольшей целевой долей' do
      ranked = strategy.rank(candidates, operation, state)

      expect(ranked.first.name).to eq('vipay')
    end

    it 'explain не делит на ноль даже при вырожденной нулевой заявке (total_after = 0)' do
      zero_operation = build_operation(amount: 0)
      ranked = strategy.rank(candidates, zero_operation, state)

      expect { strategy.explain(ranked, zero_operation, state) }.not_to raise_error
    end
  end
end
