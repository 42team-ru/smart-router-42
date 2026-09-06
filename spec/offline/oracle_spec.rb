# frozen_string_literal: true

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, Metrics/CyclomaticComplexity, Metrics/MethodLength

require 'offline/benchmark_block'
require 'offline/oracle'

RSpec.describe Offline::Oracle do
  it 'совпадает с полным перебором допустимых назначений на seed 7 и 42' do
    %w[7 42].each do |seed|
      providers, operations, outcomes = offline_context(seed: seed)
      simulation = Offline::Simulation.new(providers: providers, outcomes: outcomes)
      bound = described_class.new(providers: providers, operations: operations, outcomes: outcomes)
                             .call(Array.new(operations.size))

      expect(bound.metrics).to eq(exhaustive_best(simulation, providers, operations))
    end
  end

  # delivered на seed 42 — 9, а не 10: пер-провайдерные approved_bp/rejected_bp
  # из сглаженной истории (Io::HistoryLoader) заменили прежний плоский
  # reject_share=500 бп на всех — по конкретному брошенному хешу для этой
  # заявки исход сместился из approved в rejected. Смещение синхронное для
  # offline_bound и our_online_result (competitive_ratio остаётся 1.0), это не
  # расхождение online/offline, а честная перекалибровка симулятора.
  it 'даёт ожидаемые блоки для калиброванных seed 7 и 42' do
    expectations = { '7' => { deviation: 15.0, delivered: 10 },
                     '42' => { deviation: 5.0, delivered: 9 } }
    expectations.each do |seed, expected|
      providers, operations, outcomes = offline_context(seed: seed)
      simulation = Offline::Simulation.new(providers: providers, outcomes: outcomes)
      ours = simulation.run(operations, online_assignment)
      bound = described_class.new(providers: providers, operations: operations, outcomes: outcomes,
                                  online_metrics: ours).call(online_assignment)
      block = Offline::BenchmarkBlock.build(bound: bound.metrics, ours: ours,
                                            total: operations.size, seed: seed)

      expect(block).to include(
        'offline_bound' => include('max_deviation_pp' => expected.fetch(:deviation),
                                   'delivered' => expected.fetch(:delivered)),
        'our_online_result' => include('max_deviation_pp' => expected.fetch(:deviation),
                                       'delivered' => expected.fetch(:delivered)),
        'competitive_ratio' => 1.0
      )
    end
  end

  it 'детерминирован и не отдаёт bound хуже реальных онлайн-метрик' do
    providers, operations, outcomes = offline_context
    simulation = Offline::Simulation.new(providers: providers, outcomes: outcomes)
    ours = simulation.run(operations, online_assignment)
    oracle = described_class.new(providers: providers, operations: operations, outcomes: outcomes,
                                 online_metrics: ours)

    first = oracle.call(online_assignment)
    expect(first).to eq(oracle.call(online_assignment))
    expect(first.metrics.key <=> ours.key).to be <= 0
  end

  it 'обрабатывает 100 операций быстрее пяти секунд' do
    providers = Io::ProvidersLoader.load(reference_path('providers.json'))
    operations = Io::QueueLoader.load(fixture_path('queues', 'queue_100.json')).operations
    outcomes = offline_context.last
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    described_class.new(providers: providers, operations: operations, outcomes: outcomes)
                   .call(Array.new(operations.size))

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
  end

  def exhaustive_best(simulation, providers, operations)
    assignments(providers, operations).map { |assignment| simulation.run(operations, assignment) }
                                      .min_by(&:key)
  end

  def online_assignment
    %w[vipay payflow quickpay quickpay vipay vipay payflow quickpay vipay payflow]
  end

  def assignments(providers, operations)
    choices = operations.map do |operation|
      providers.reject { |provider| provider.name == 'spacepayments' }
               .select do |provider|
        Routing::Constraints.eligible?(provider,
                                       operation)
      end.map(&:name)
    end
    choices.reduce([[]]) do |partial, names|
      partial.flat_map do |row|
        names.map do |name|
          row + [name]
        end
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, Metrics/CyclomaticComplexity, Metrics/MethodLength
