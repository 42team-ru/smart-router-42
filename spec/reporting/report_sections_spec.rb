# frozen_string_literal: true

require 'io/history_loader'
require 'io/queue_loader'
require 'reporting/outcome_distribution'
require 'reporting/latency_profile'
require 'reporting/queue_coverage'
require 'reporting/input_diagnostics'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
# -- один сценарий проверяет связанный контракт каждой секции целиком.
RSpec.describe 'Дополнительные секции отчёта' do
  let(:history) { Io::HistoryLoader.load('reference/data/operations_history.csv') }

  it 'показывает реальные исторические исходы, а не always_ok текущей очереди' do
    section = Reporting::OutcomeDistribution.build(history, 'reference/data/operations_history.csv')

    expect(section.dig('total', 'rejected')).to eq('count' => 16, 'share_pct' => 16.0)
    expect(section.dig('by_provider', 'payflow', 'approved', 'share_pct')).to eq(47.4)
  end

  it 'считает процентили методом ближайшего ранга' do
    rows = [5, 10, 20, 40, 100].map do |latency|
      { 'payment_system' => 'vipay', 'status' => 'approved', 'latency_sec' => latency.to_s }
    end
    stats = Io::HistoryStats.new(entries: {}, k: 0, smoothed: false, rows: rows, diagnostics: {})

    expect(Reporting::LatencyProfile.build(stats, 'test.csv').fetch('total'))
      .to include('p50_sec' => 20, 'p95_sec' => 100)
  end

  it 'сохраняет инвариант покрытия для дубля и невалидной суммы' do
    raw = [{ 'operation_id' => 'a', 'created_at' => 'x', 'amount' => 1, 'bank' => 'b',
             'payout_requisite' => {} },
           { 'operation_id' => 'a', 'created_at' => 'x', 'amount' => 1, 'bank' => 'b',
             'payout_requisite' => {} },
           { 'operation_id' => 'c', 'created_at' => 'x', 'amount' => 0, 'bank' => 'b',
             'payout_requisite' => {} }]
    result = Io::QueueLoader::Builder.new(raw).call
    section = Reporting::QueueCoverage.build(result, Array.new(result.operations.size))

    expect(section.values_at('with_decision', 'dropped', 'queue_operations')).to eq([1, 2, 3])
    expect(section['coverage_pct']).to eq(33.3)
  end

  it 'считает диагностические строки истории' do
    result = Io::QueueLoader::Builder.new([]).call
    diagnostics = Reporting::InputDiagnostics.build(result, history, [])['history']

    expect(diagnostics).to include('rows' => 100, 'unparsable_latency' => 0,
                                   'unknown_result' => 0)
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
