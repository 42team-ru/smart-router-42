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
    Result = Data.define(:accumulator, :report, :measurement, :operations_seen)

    # rubocop:disable-next Metrics/ParameterLists -- шесть независимых источников входа, как у build_pipeline в bin/route.
    def initialize(providers_path:, queue_path:, config_path:, expectation:, mode:, seed:)
      @providers_path = providers_path
      @queue_path = queue_path
      @config_path = config_path
      @expectation = expectation
      @mode = mode
      @seed = seed
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
      queue_errors = stream_operations do |operation|
        plan = pipeline[:planner].plan(operation, pipeline[:state])
        outcome = pipeline[:executor].run(plan, operation, pipeline[:state])
        accumulator.add(operation, outcome)
        comparator.observe(operation, outcome)
        seen += 1
      end
      accumulator.queue_errors = queue_errors
      measurement = Measurement.snapshot(started, gc_before)

      Result.new(accumulator: accumulator, report: comparator.finish(accumulator),
                 measurement: measurement, operations_seen: seen)
    end

    private

    def build_pipeline(providers, config)
      planner = Routing::Planner.new(
        providers: providers, strategy: Routing::Assembly.strategy(config: config, override: nil),
        selector: Routing::Assembly.selector(config: config, override: nil),
        fallback_provider: config.fallback_provider,
        layers: Routing::LayerStack.new(Routing::Assembly.layers(config: config))
      )
      { planner: planner, executor: Execution::Executor.new(outcomes: build_outcomes(providers)),
        state: State::Providers.new(providers) }
    end

    def build_outcomes(providers)
      conversions = providers.to_h { |provider| [provider.name, provider.conversion_24h.to_f] }
      Execution::OutcomeSource::Deterministic.new(seed: @seed, conversions: conversions)
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
