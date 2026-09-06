# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'reporting/decisions_writer'
require 'domain/operation'
require 'domain/provider'
require 'routing/attempt'
require 'execution/outcome'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- каждый пример собирает
# решение из Operation+Outcome и проверяет связанные утверждения об одном и том же файле,
# дробить их — терять контекст сценария
RSpec.describe Reporting::DecisionsWriter do
  def build_provider(name, avg_latency_sec:)
    Domain::Provider.new(
      payment_system: name, status: nil, traffic_percentage: nil, priority: nil,
      limit_amount_min: nil, limit_amount_max: nil, daily_amount_limit: nil,
      daily_approved_amount: nil, in_progress_count_limit: nil, in_progress_count: nil,
      in_progress_amount_limit: nil, in_progress_amount: nil, available_requisites: nil,
      conversion_24h: nil, avg_latency_sec: avg_latency_sec, banks: nil, exclude_banks: nil,
      provider_margin_pct: nil, merchant_margin_pct: nil, allow_negative_agreement: nil,
      volume_share_pct: nil, requests_per_minute_limit: nil, daily_turnover_min: nil,
      daily_turnover_max: nil
    )
  end

  def build_attempt(raw)
    Routing::Attempt.new(**raw.transform_keys(&:to_sym))
  end

  def load_fixture_decisions
    JSON.parse(File.read(fixture_path('contracts', 'decisions.json')))
  end

  # Воспроизводит op_103 из spec/fixtures/contracts/decisions.json: quickpay
  # допустим единственным, никаких отказов.
  let(:operation) do
    Domain::Operation.new(operation_id: 'op_103', created_at: nil, amount: 150_000,
                          bank: 'sberbank', card_brand: nil, payout_requisite: nil)
  end
  let(:quickpay) { build_provider('quickpay', avg_latency_sec: 29) }
  let(:outcome) do
    attempts = [
      build_attempt('provider' => 'vipay', 'decision' => 'skipped',
                    'reason' => 'amount_exceeds_limit',
                    'details' => '150000 > limit_amount_max 100000'),
      build_attempt('provider' => 'payflow', 'decision' => 'skipped',
                    'reason' => 'amount_exceeds_limit',
                    'details' => '150000 > limit_amount_max 50000'),
      build_attempt('provider' => 'quickpay', 'decision' => 'selected',
                    'reason' => 'only_eligible_provider',
                    'details' => '1 допустимый провайдер из 3', 'strategy' => 'count_share',
                    'attempt_no' => 1, 'result' => 'approved')
    ]
    Execution::Outcome.new(selected: quickpay, attempts: attempts, result: :approved)
  end

  describe '.build_decision' do
    it 'собирает решение побайтово как в контрактной фикстуре op_103' do
      expected = load_fixture_decisions.find { |d| d['operation_id'] == 'op_103' }

      decision = described_class.build_decision(operation, outcome)
      roundtripped = JSON.parse(JSON.generate(decision))

      expect(roundtripped).to eq(expected)
    end
  end

  describe '.build' do
    it 'собирает массив решений в порядке входных пар' do
      decisions = described_class.build([[operation, outcome]])

      expect(decisions.map { |d| d['operation_id'] }).to eq(['op_103'])
    end
  end

  describe '.write' do
    it 'пишет JSON с завершающим переводом строки и без экранирования кириллицы' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'routing_decisions_test.json')

        described_class.write(path, [[operation, outcome]])
        content = File.read(path)

        expect(content).to end_with("\n")
        expect(content).to include('допустимый провайдер')
        expect(JSON.parse(content).first['operation_id']).to eq('op_103')
      end
    end

    it 'даёт побайтово одинаковый результат на двух записях подряд' do
      Dir.mktmpdir do |dir|
        path_a = File.join(dir, 'a.json')
        path_b = File.join(dir, 'b.json')

        described_class.write(path_a, [[operation, outcome]])
        described_class.write(path_b, [[operation, outcome]])

        expect(File.binread(path_a)).to eq(File.binread(path_b))
      end
    end

    # Пустая очередь -- частный случай, который потоковая склейка "[" +
    # запятые + "]" обязана не сломать: JSON.pretty_generate([]) даёт "[]"
    # без единой пустой строки внутри, а не "[\n\n]".
    it 'на пустой очереди даёт ровно [] и перевод строки' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'empty.json')

        described_class.write(path, [])

        expect(File.binread(path)).to eq("[]\n")
      end
    end

    # Регресс на пакет 3: раньше write собирал JSON.pretty_generate(build(pairs))
    # одной строкой в памяти, теперь пишет потоком по одному решению. Обе
    # стратегии обязаны давать один и тот же байтовый результат на очереди из
    # нескольких операций с разными формами attempts -- skipped, несколько
    # попыток каскада, fallback.
    it 'совпадает побайтово с JSON.pretty_generate(build(pairs)) на очереди ' \
       'из нескольких операций с разными формами attempts' do
      spacepayments = build_provider('spacepayments', avg_latency_sec: 5)
      other_operation = Domain::Operation.new(operation_id: 'op_200', created_at: nil,
                                              amount: 90_000, bank: 'tinkoff', card_brand: nil,
                                              payout_requisite: nil)
      other_attempts = [
        build_attempt('provider' => 'vipay', 'decision' => 'skipped',
                      'reason' => 'amount_exceeds_limit',
                      'details' => '90000 > limit_amount_max 50000'),
        build_attempt('provider' => 'payflow', 'decision' => 'selected',
                      'reason' => 'best_target_adherence', 'details' => 'кандидат единственный',
                      'strategy' => 'count_share', 'attempt_no' => 1, 'result' => 'rejected'),
        build_attempt('provider' => 'spacepayments', 'decision' => 'selected',
                      'reason' => 'fallback_no_eligible_provider',
                      'details' => 'допустимых внешних провайдеров 0 из 2',
                      'strategy' => 'fallback', 'attempt_no' => 2, 'result' => 'approved')
      ]
      other_outcome = Execution::Outcome.new(selected: spacepayments, attempts: other_attempts,
                                             result: :approved)
      pairs = [[operation, outcome], [other_operation, other_outcome]]
      expected = "#{JSON.pretty_generate(described_class.build(pairs))}\n"

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'routing_decisions_test.json')

        described_class.write(path, pairs)

        expect(File.read(path)).to eq(expected)
      end
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
