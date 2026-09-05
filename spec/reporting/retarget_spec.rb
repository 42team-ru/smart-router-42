# frozen_string_literal: true

require 'reporting/retarget'
require 'io/providers_loader'
require 'io/queue_loader'
require 'routing/achievable'
require 'routing/constraints'
require 'offline/objective'
require 'domain/provider'

# Retarget на настоящей публичной очереди (reference/data) -- те же входные
# данные, что и у spec/reporting/deviation_causes_spec.rb, потому что обе
# проверки используют один и тот же Routing::Achievable.for_queue.
RSpec.describe Reporting::Retarget do
  # rubocop:disable-next RSpec/MultipleMemoizedHelpers -- providers/operations/eligibility/achievable/metrics образуют один сценарий.
  describe 'на реальной публичной очереди (reference/data)' do
    let(:providers) { Io::ProvidersLoader.load(reference_path('providers.json')) }
    let(:operations) { Io::QueueLoader.load(reference_path('operations_queue_10.json')).operations }
    let(:external) { providers.reject { |provider| provider.name == 'spacepayments' } }

    let(:eligibility) do
      operations.to_h do |operation|
        names = external.select { |provider| Routing::Constraints.eligible?(provider, operation) }
        [operation.operation_id, names.map(&:name)]
      end
    end

    let(:achievable) do
      Routing::Achievable.for_queue(operations: operations, providers: providers,
                                    eligibility: eligibility)
    end

    # Реальные итоговые счётчики дефолтного прогона: vipay 4, payflow 3,
    # quickpay 3, spacepayments 0 (routing_decisions_test.json).
    let(:metrics) do
      Offline::Objective.metrics(counts: { 'vipay' => 4, 'payflow' => 3, 'quickpay' => 3,
                                           'spacepayments' => 0 },
                                 delivered: 10, providers: providers, total: 10)
    end

    it 'предлагает достижимую точку 40/30/30 вместо паспортной 40/35/25' do
      result = described_class.build(providers, achievable, metrics)

      expect(result).to include('vipay 40%', 'payflow 35% → 30%', 'quickpay 25% → 30%')
    end

    # rubocop:disable-next RSpec/MultipleExpectations -- обе причины из одного результата.
    it 'называет структурную причину для каждого изменившегося провайдера' do
      result = described_class.build(providers, achievable, metrics)

      expect(result).to include('payflow ограничен дневным лимитом')
      expect(result).to include('quickpay форсирован отсутствием альтернатив у части операций')
    end

    it 'эффект — максимальное отклонение падает с 5 до 0 п.п.' do
      result = described_class.build(providers, achievable, metrics)

      expect(result).to end_with('падает с 5 до 0 п.п.')
    end
  end

  describe 'синтетические края контракта' do
    include ProviderFactory

    let(:vipay) { build_provider(payment_system: 'vipay', traffic_percentage: 50) }
    let(:payflow) { build_provider(payment_system: 'payflow', traffic_percentage: 50) }
    let(:providers) { [vipay, payflow] }
    let(:metrics) do
      Offline::Objective.metrics(counts: { 'vipay' => 1, 'payflow' => 1 }, delivered: 2,
                                 providers: providers, total: 2)
    end

    it 'возвращает nil, когда паспортные цели уже достижимы' do
      achievable = {
        'vipay' => { target_bp: 5000, achievable_seats: 1, achievable_bp: 5000, bound: :none },
        'payflow' => { target_bp: 5000, achievable_seats: 1, achievable_bp: 5000, bound: :none }
      }

      expect(described_class.build(providers, achievable, metrics)).to be_nil
    end

    it 'возвращает nil без структурной причины (bound :none у всех изменившихся)' do
      # Достижимое (30/70) расходится с паспортным (50/50), но ни один
      # bound не :only_option/:money -- retarget без причины хуже отсутствия
      # retarget (см. lib/reporting/retarget.rb).
      achievable = {
        'vipay' => { target_bp: 5000, achievable_seats: 0, achievable_bp: 3000, bound: :none },
        'payflow' => { target_bp: 5000, achievable_seats: 2, achievable_bp: 7000, bound: :none }
      }

      expect(described_class.build(providers, achievable, metrics)).to be_nil
    end
  end
end
