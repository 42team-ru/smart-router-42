# frozen_string_literal: true

require 'reporting/console_summary'
require 'domain/operation'
require 'routing/attempt'
require 'execution/outcome'

RSpec.describe Reporting::ConsoleSummary do
  include ProviderFactory

  describe '.operation_lines' do
    # rubocop:disable-next RSpec/ExampleLength -- сборка фикстуры без общих let.
    it 'печатает операцию, сумму, провайдера, исход и причину с числом' do
      operation = build_operation(operation_id: 'op_101', amount: 15_000)
      attempt = Routing::Attempt.new(provider: 'vipay', decision: 'selected',
                                     reason: 'first_eligible', details: '2 допустимых из 2',
                                     attempt_no: 1, result: 'approved')
      outcome = Execution::Outcome.new(selected: build_provider(payment_system: 'vipay'),
                                       attempts: [attempt], result: :approved)

      lines = described_class.operation_lines([[operation, outcome]])

      expect(lines).to eq(
        ['op_101  15 000 ₽ → vipay (approved)  first_eligible: 2 допустимых из 2']
      )
    end

    # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- один сценарий каскада.
    it 'берёт последнюю selected-попытку — ту, что решила исход, а не первый отказ каскада' do
      operation = build_operation(operation_id: 'op_102', amount: 48_000)
      rejected_attempt = Routing::Attempt.new(provider: 'payflow', decision: 'selected',
                                              reason: 'first_eligible', details: '2 из 2',
                                              attempt_no: 1, result: 'rejected')
      approved_attempt = Routing::Attempt.new(provider: 'quickpay', decision: 'selected',
                                              reason: 'next_in_cascade',
                                              details: 'payflow отказал на попытке 1, попытка 2',
                                              attempt_no: 2, result: 'approved')
      outcome = Execution::Outcome.new(selected: build_provider(payment_system: 'quickpay'),
                                       attempts: [rejected_attempt, approved_attempt],
                                       result: :approved)

      line = described_class.operation_lines([[operation, outcome]]).first

      expect(line).to include('quickpay (approved)')
      expect(line).to include('next_in_cascade: payflow отказал на попытке 1, попытка 2')
      expect(line).not_to include('first_eligible')
    end

    # rubocop:disable-next RSpec/ExampleLength -- сборка фикстуры без общих let.
    it 'игнорирует skipped-попытки допуска при поиске решившей исход' do
      operation = build_operation(operation_id: 'op_107', amount: 800)
      skipped = Routing::Attempt.new(provider: 'vipay', decision: 'skipped',
                                     reason: 'amount_below_minimum', details: '800 < 1000')
      selected = Routing::Attempt.new(provider: 'payflow', decision: 'selected',
                                      reason: 'only_eligible_provider',
                                      details: '1 допустимый из 1',
                                      attempt_no: 1, result: 'approved')
      outcome = Execution::Outcome.new(selected: build_provider(payment_system: 'payflow'),
                                       attempts: [skipped, selected], result: :approved)

      line = described_class.operation_lines([[operation, outcome]]).first

      expect(line).to include('only_eligible_provider: 1 допустимый из 1')
    end
  end

  describe '.summary_lines' do
    let(:report) do
      {
        'distribution' => {
          'vipay' => { 'count' => 4, 'share_pct' => 40.0, 'target_pct' => 40,
                       'achievable_pct' => 40.0 },
          'spacepayments' => { 'count' => 0, 'share_pct' => 0.0, 'target_pct' => 0,
                               'achievable_pct' => nil }
        },
        'fallback' => { 'first_attempt_success' => 8, 'recovered_by_fallback' => 0,
                        'spacepayments_used' => 0, 'cascade_exhausted' => 2 },
        'benchmark' => {
          'offline_bound' => { 'max_deviation_pp' => 5.0, 'delivered' => 10 },
          'our_online_result' => { 'max_deviation_pp' => 5.0, 'delivered' => 10 },
          'competitive_ratio' => 1.0, 'note' => 'note'
        },
        'deviation_causes' => ['quickpay +5 п.п. к цели: op_103 не имел альтернатив'],
        'recommendations' => ['retarget: паспортные цели недостижимы']
      }
    end

    it 'печатает распределение с достижимой долей, если она есть' do
      expect(described_class.summary_lines(report))
        .to include('  vipay: 4 (40.0% / 40% / 40.0%)')
    end

    it 'печатает прочерк вместо достижимой доли, когда её нет (spacepayments)' do
      expect(described_class.summary_lines(report))
        .to include('  spacepayments: 0 (0.0% / 0% / —)')
    end

    it 'печатает fallback-сводку' do
      expect(described_class.summary_lines(report)).to include(
        'Fallback: 8 с первой попытки, 0 восстановлено каскадом, 0 в spacepayments, ' \
        '2 каскад исчерпан'
      )
    end

    it 'печатает competitive_ratio и оба отклонения из benchmark' do
      expect(described_class.summary_lines(report))
        .to include('Benchmark: competitive_ratio=1.0 (эталон 5.0 п.п., наш 5.0 п.п.)')
    end

    # rubocop:disable-next RSpec/MultipleExpectations -- оба факта про один вызов.
    it 'печатает каждую причину отклонения и каждую рекомендацию отдельной строкой' do
      lines = described_class.summary_lines(report)

      expect(lines).to include(
        'Причина отклонения: quickpay +5 п.п. к цели: op_103 не имел альтернатив'
      )
      expect(lines).to include('Рекомендация: retarget: паспортные цели недостижимы')
    end

    it 'печатает н/д вместо competitive_ratio, когда эталон не считался' do
      report['benchmark'] = { 'offline_bound' => nil, 'our_online_result' => nil,
                              'competitive_ratio' => nil, 'note' => 'эталон не считался' }

      expect(described_class.summary_lines(report))
        .to include('Benchmark: competitive_ratio=н/д (эталон н/д п.п., наш н/д п.п.)')
    end
  end
end
