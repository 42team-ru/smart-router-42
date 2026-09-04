# frozen_string_literal: true

require 'reporting/deviation_causes'
require 'io/providers_loader'
require 'io/queue_loader'
require 'routing/achievable'
require 'routing/constraints'
require 'domain/provider'
require 'domain/operation'
require 'execution/outcome'

RSpec.describe Reporting::DeviationCauses do
  # rubocop:disable-next RSpec/MultipleMemoizedHelpers -- providers/operations/eligibility/achievable образуют один сценарий.
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
    let(:by_name) { providers.to_h { |provider| [provider.name, provider] } }

    # Итоговые провайдеры взяты из уже прогнанного и проверенного
    # routing_decisions_test.json (дефолтный конфиг, count_share, seed 42) --
    # не пересобираются здесь Planner-ом/Executor-ом, чтобы тест не зависел
    # от деталей их устройства, а только от контракта DeviationCauses.build.
    let(:selected_by_operation) do
      {
        'op_101' => 'vipay', 'op_102' => 'payflow', 'op_103' => 'quickpay',
        'op_104' => 'quickpay', 'op_105' => 'vipay', 'op_106' => 'vipay',
        'op_107' => 'payflow', 'op_108' => 'quickpay', 'op_109' => 'vipay',
        'op_110' => 'payflow'
      }
    end
    let(:pairs) do
      operations.map do |operation|
        selected = by_name.fetch(selected_by_operation.fetch(operation.operation_id))
        [operation, Execution::Outcome.new(selected: selected, attempts: [], result: :approved)]
      end
    end
    let(:causes) { described_class.build(pairs, providers, achievable, eligibility) }

    it 'quickpay: перегружен вынужденными операциями -- перечисляет их поимённо' do
      expect(causes).to include(
        'quickpay +5 п.п. к цели: op_103, op_104, op_108 не имели альтернатив по сумме и банку'
      )
    end

    it 'payflow: урезан дневным лимитом -- причина числовая, без наблюдения' do
      expect(causes).to include(a_string_matching(/\Apayflow -5 п\.п\. к цели: дневной лимит/))
    end

    it 'vipay: отклонение 0.0, ниже порога -- в списке причин отсутствует' do
      expect(causes.grep(/\Avipay /)).to be_empty
    end

    # rubocop:disable-next RSpec/MultipleExpectations -- оба факта об одном инварианте.
    it 'spacepayments никогда не попадает в объяснение причин (его нет в achievable)' do
      expect(achievable).not_to have_key('spacepayments')
      expect(causes.grep(/spacepayments/)).to be_empty
    end

    it 'порог включает отклонение, равное ровно 5.0 п.п. (регрессия на > вместо >=)' do
      expect(causes.size).to eq(2)
    end
  end

  describe 'синтетические края контракта' do
    include ProviderFactory

    # target_pct занижен намеренно (10%, а не паспортные 40) -- иначе реальная
    # доля (1 из 2 = 50%) не отклонится от цели даже на 5 п.п., и порог из §0
    # не сработает вовсе.
    let(:vipay) { build_provider(payment_system: 'vipay', traffic_percentage: 10) }
    let(:payflow) { build_provider(payment_system: 'payflow', traffic_percentage: 90) }
    let(:providers) { [vipay, payflow] }
    let(:op_a) { build_operation(operation_id: 'op_a') }
    let(:op_b) { build_operation(operation_id: 'op_b') }

    # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- один сценарий с двумя сторонами одного факта.
    it 'не перечисляет операцию, единственно допустимую для провайдера, но ушедшую не ему' do
      # Обе операции singleton-допустимы только для vipay, но op_a по факту
      # (хард-отказ, каскад) ушла payflow. "op_a не имел альтернатив" было бы
      # неправдой в причине vipay -- он не получил эту операцию.
      eligibility = { 'op_a' => ['vipay'], 'op_b' => ['vipay'] }
      achievable = {
        'vipay' => { target_bp: 1000, achievable_seats: 2, achievable_bp: 10_000,
                     bound: :only_option },
        'payflow' => { target_bp: 9000, achievable_seats: 0, achievable_bp: 0, bound: :money }
      }
      pairs = [
        [op_a, Execution::Outcome.new(selected: payflow, attempts: [], result: :approved)],
        [op_b, Execution::Outcome.new(selected: vipay, attempts: [], result: :approved)]
      ]

      causes = described_class.build(pairs, providers, achievable, eligibility)
      vipay_cause = causes.find { |cause| cause.start_with?('vipay') }

      expect(vipay_cause).to include('op_b')
      expect(vipay_cause).not_to include('op_a')
    end

    # rubocop:disable-next RSpec/ExampleLength -- сборка фикстуры без общих let, сценарий локальный.
    it 'возвращает пустой массив, если ни одно отклонение не достигает порога' do
      # Собственные провайдеры с целью 50/50, совпадающей с фактом (1 из 2
      # каждому) -- переиспользование vipay/payflow из теста выше (цели 10/90)
      # дало бы деградировавшее отклонение 40 п.п. и ложно провалило бы тест.
      balanced_vipay = build_provider(payment_system: 'vipay', traffic_percentage: 50)
      balanced_payflow = build_provider(payment_system: 'payflow', traffic_percentage: 50)
      eligibility = { 'op_a' => %w[vipay payflow], 'op_b' => %w[vipay payflow] }
      achievable = {
        'vipay' => { target_bp: 5000, achievable_seats: 1, achievable_bp: 5000, bound: :none },
        'payflow' => { target_bp: 5000, achievable_seats: 1, achievable_bp: 5000, bound: :none }
      }
      pairs = [
        [op_a, Execution::Outcome.new(selected: balanced_vipay, attempts: [], result: :approved)],
        [op_b, Execution::Outcome.new(selected: balanced_payflow, attempts: [], result: :approved)]
      ]

      expect(
        described_class.build(pairs, [balanced_vipay, balanced_payflow], achievable, eligibility)
      ).to eq([])
    end
  end
end
