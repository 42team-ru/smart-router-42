# frozen_string_literal: true

require_relative '../io/providers_loader'
require_relative '../io/queue_loader'
require_relative '../io/queue_stream_loader'
require_relative '../config/loader'
require_relative '../routing/assembly'
require_relative '../routing/planner'
require_relative '../routing/layer_stack'
require_relative '../state/providers'
require_relative '../execution/executor'
require_relative '../execution/outcome_source/deterministic'
require_relative '../offline/objective'
require_relative '../offline/oracle'
require_relative '../offline/benchmark_block'
require_relative 'accumulator'
require_relative 'comparator'
require_relative 'measurement'

module Bench
  # Повторяет build_pipeline/route_operation из bin/route (тот же
  # Routing::Planner + Execution::Executor + Config::Assembly), но не копит
  # pairs и не пишет decisions.json — только Accumulator и Comparator видят
  # каждую пару, O(1) на операцию. Это ядро всех уровней бенчмарка, включая
  # smoke/s/m: полный CLI с записью файлов — отдельно, через
  # `make gen && bundle exec bin/route ...` (см. README к бенчмарку).
  class Runner
    Result = Data.define(:accumulator, :report, :measurement, :operations_seen, :benchmark)

    # rubocop:disable-next Metrics/ParameterLists -- шесть независимых источников входа, как у build_pipeline в bin/route.
    def initialize(providers_path:, queue_path:, config_path:, expectation:, mode:, seed:,
                   run_oracle: false)
      @providers_path = providers_path
      @queue_path = queue_path
      @config_path = config_path
      @expectation = expectation
      @mode = mode
      @seed = seed
      # Оракулу нужна вся очередь и назначения целиком — на потоковых уровнях
      # (:jsonl) этого нет по построению, там очередь и не помещается в память.
      @run_oracle = run_oracle && mode == :array
    end

    # rubocop:disable-next Metrics/MethodLength, Metrics/AbcSize
    def run
      Routing::Strategies.load_all!
      Routing::Layers.load_all!
      providers = Io::ProvidersLoader.load(@providers_path)
      config = Config::Loader.load(@config_path)
      pipeline = build_pipeline(providers, config)
      accumulator = Accumulator.new(provider_names: providers.map(&:name))
      comparator = Comparator.new(@expectation, providers: providers,
                                                fallback_name: config.fallback_provider)

      started = Measurement.now
      gc_before = GC.stat
      seen = 0
      trace = @run_oracle ? [] : nil
      queue_errors = stream_operations do |operation|
        plan = pipeline[:planner].plan(operation, pipeline[:state])
        outcome = pipeline[:executor].run(plan, operation, pipeline[:state])
        accumulator.add(operation, outcome)
        comparator.observe(operation, outcome)
        trace&.push([operation, outcome])
        seen += 1
      end
      accumulator.queue_errors = queue_errors
      measurement = Measurement.snapshot(started, gc_before)

      Result.new(accumulator: accumulator, report: comparator.finish(accumulator),
                 measurement: measurement, operations_seen: seen,
                 benchmark: build_benchmark(trace, providers, config, pipeline))
    end

    private

    # Эталон считается постфактум по уже собранным парам — ровно как в bin/route
    # и с теми же классами lib/offline, поэтому competitive_ratio здесь значит
    # то же, что в боевом отчёте. На очередях длиннее Oracle::LOCAL_SEARCH_MAX_OPS
    # локальные улучшения отключаются самим оракулом, остаётся жадная оценка:
    # 3 симуляции очереди вместо O(n·m), это и делает уровень m посильным.
    def build_benchmark(trace, providers, config, pipeline)
      return nil if trace.nil? || trace.empty?

      ours = Offline::Objective.from_pairs(trace, providers: providers)
      bound = build_oracle(trace, providers, config, pipeline, ours)
              .call(Offline::Oracle.online_assignment(trace))
      Offline::BenchmarkBlock.build(
        bound: bound.metrics, ours: ours, total: trace.size, seed: @seed.to_s,
        local_search_skipped: trace.size > Offline::Oracle::LOCAL_SEARCH_MAX_OPS
      )
    end

    def build_oracle(trace, providers, config, pipeline, ours)
      Offline::Oracle.new(
        providers: providers, operations: trace.map(&:first), outcomes: pipeline[:outcomes],
        fallback_provider: config.fallback_provider, online_metrics: ours
      )
    end

    def build_pipeline(providers, config)
      planner = Routing::Planner.new(
        providers: providers, strategy: Routing::Assembly.strategy(config: config, override: nil),
        selector: Routing::Assembly.selector(config: config, override: nil),
        fallback_provider: config.fallback_provider,
        layers: Routing::LayerStack.new(Routing::Assembly.layers(config: config))
      )
      outcomes = build_outcomes(providers)
      { planner: planner, executor: Execution::Executor.new(outcomes: outcomes),
        outcomes: outcomes, state: State::Providers.new(providers) }
    end

    # Бенчмарк всегда паспортный (conversion_24h) -- у него нет своего конфига
    # с outcomes.calibrate_from_history, история сюда не прокидывается.
    def build_outcomes(providers)
      Execution::OutcomeSource::Deterministic.new(
        seed: @seed,
        outcome_table: Execution::OutcomeSource::Deterministic.passport_outcome_table(providers)
      )
    end

    def stream_operations(&)
      if @mode == :jsonl
        Io::QueueStreamLoader.each(@queue_path, &).errors.size
      else
        result = Io::QueueLoader.load(@queue_path)
        result.operations.each(&)
        result.errors.size
      end
    end
  end
end
