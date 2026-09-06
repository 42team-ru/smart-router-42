# frozen_string_literal: true

require_relative 'objective'
require_relative '../execution/executor'
require_relative '../execution/outcome_source/always_ok'
require_relative '../execution/outcome_source/deterministic'
require_relative '../routing/achievable'
require_relative '../routing/constraints'
require_relative '../routing/layer_stack'
require_relative '../routing/layers'
require_relative '../routing/planner'
require_relative '../routing/selector'
require_relative '../routing/strategies'
require_relative '../reporting/distributions'
require_relative '../state/providers'

module Offline
  # Офлайн-сравнение конфигураций стратегия+слои на той же очереди. Постфактум,
  # как офлайн-оптимум --
  # результат идёт только в отчёт и в консоль, никогда в принятие решений
  # (spec/offline/isolation_spec.rb это стережёт, как и остальной Offline).
  #
  # Каждый вариант -- такой же ОНЛАЙН-проход по очереди (заглядывать в будущие
  # операции нельзя и здесь), но на СВОЁМ State::Providers и своём экземпляре
  # источника исходов: варианты не делят состояние друг с другом, поэтому
  # порядок их прогона не протекает в цифры (Execution::OutcomeSource::Deterministic
  # -- чистая функция seed+id+attempt_no, без памяти).
  # rubocop:disable-next Metrics/ModuleLength -- метрики вариантов собраны рядом для общей изоляции состояния.
  module Comparison
    NOTE = 'офлайн-сравнение: тот же онлайн-проход по очереди под другой стратегией/слоями, ' \
           'каждый вариант на своём состоянии; результат идёт только в отчёт и в консоль, ' \
           'в принятие решений не входит'
    FALLBACK_PROVIDER = 'spacepayments'

    # variants: [{"name"=>.., "strategy"=>.., "layers"=>[...]}], уже
    # провалидированы конфигом (Config::SchemaRules.validate_comparison!).
    # baseline: имя варианта, совпадающего с боевым strategy/layers -- вызывающая
    # сторона (bin/route) находит его сама, схема гарантирует, что он есть.
    # rubocop:disable-next Metrics/ParameterLists -- шесть источников (варианты,
    # очередь, снапшот, конфиг, история, имя baseline) не сжимаются без потери
    # именованности на вызывающей стороне (bin/route).
    def self.build(variants:, operations:, providers:, config:, history:, baseline:)
      achievable = achievable_for(operations, providers)
      variant_metrics = variants.to_h do |variant|
        [variant.fetch('name'),
         metrics_for(variant, operations, providers, config, history, achievable)]
      end
      { 'baseline' => baseline, 'variants' => variant_metrics, 'note' => NOTE }
    end

    # Один изолированный контрфактуальный прогон. Используется аналитикой
    # рекомендаций: новый State::Providers не может изменить боевой результат.
    def self.evaluate(operations:, providers:, config:, history:)
      achievable = achievable_for(operations, providers)
      variant = { 'strategy' => config.strategy, 'layers' => config.layers }
      metrics_for(variant, operations, providers, config, history, achievable)
    end

    def self.achievable_for(operations, providers)
      eligibility = eligibility_for(operations, providers)
      Routing::Achievable.for_queue(operations: operations, providers: providers,
                                    eligibility: eligibility)
    end
    private_class_method :achievable_for

    def self.eligibility_for(operations, providers)
      external = providers.reject { |provider| provider.name == FALLBACK_PROVIDER }
      operations.to_h do |operation|
        names = external.select { |provider| Routing::Constraints.eligible?(provider, operation) }
        [operation.operation_id, names.map(&:name)]
      end
    end
    private_class_method :eligibility_for

    # rubocop:disable-next Metrics/ParameterLists -- шесть входов отражают шесть
    # независимых источников метрик одного варианта (очередь, снапшот, конфиг,
    # история, уже посчитанная достижимость).
    def self.metrics_for(variant, operations, providers, config, history, achievable)
      pairs = run_variant(variant, operations, providers, config, history)
      objective = Objective.from_pairs(pairs, providers: providers)
      distribution = Reporting::Distributions.by_final(pairs, providers, :count, achievable)

      {
        'delivered' => objective.delivered,
        'fallback_used' => fallback_used(pairs, config.fallback_provider),
        'retried' => retried(pairs),
        'max_deviation_pp' => max_abs_deviation_pp(distribution),
        'max_deviation_from_target_pp' => objective.max_deviation_pp
      }
    end
    private_class_method :metrics_for

    def self.run_variant(variant, operations, providers, config, history)
      state = State::Providers.new(providers)
      strategy = Routing::Strategies.build(variant.fetch('strategy'), config: config)
      layers = variant.fetch('layers', []).map { |name| Routing::Layers.build(name, config: config) }
      planner = build_planner(providers, strategy, layers, config)
      executor = build_executor(config, providers, history)

      operations.map do |operation|
        plan = planner.plan(operation, state)
        [operation, executor.run(plan, operation, state)]
      end
    end
    private_class_method :run_variant

    def self.build_planner(providers, strategy, layers, config)
      Routing::Planner.new(
        providers: providers, strategy: strategy, selector: Routing::Selector::Static.new(strategy),
        fallback_provider: config.fallback_provider, layers: Routing::LayerStack.new(layers)
      )
    end
    private_class_method :build_planner

    # Дефолты -- last_candidate и stop, как в bin/route
    # (cascade_exhausted/cascade_on_timeout) и в config/routing.yml. Три копии
    # одного и того же дефолта на одном и том же config.cascade -- расхождение
    # хотя бы в одной незаметно рассинхронизирует офлайн-сравнение с боевым
    # каскадом.
    def self.build_executor(config, providers, history)
      Execution::Executor.new(
        outcomes: build_outcomes(config, providers, history),
        exhausted: config.cascade.fetch('exhausted', 'last_candidate').to_sym,
        on_timeout: config.cascade.fetch('on_timeout', 'stop').to_sym
      )
    end
    private_class_method :build_executor

    def self.build_outcomes(config, providers, history)
      source = config.outcomes.fetch('source', 'deterministic')
      return Execution::OutcomeSource::AlwaysOk.new if source == 'always_ok'
      return deterministic_outcomes(config, providers, history) if source == 'deterministic'

      raise ArgumentError, "Offline::Comparison: неизвестный источник исходов #{source.inspect}"
    end
    private_class_method :build_outcomes

    def self.deterministic_outcomes(config, providers, history)
      Execution::OutcomeSource::Deterministic.new(
        seed: config.outcomes.fetch('seed', '42'),
        outcome_table: outcome_table(config, providers, history)
      )
    end
    private_class_method :deterministic_outcomes

    # Тот же выбор таблицы, что и outcome_table в bin/route: паспортная
    # (Deterministic.passport_outcome_table) строится для ВСЕХ провайдеров
    # снапшота и остаётся базой; калибровка из истории (если включена)
    # накладывается поверх только там, где история реально есть.
    # spacepayments (self-provider фолбэка, в operations_history.csv его нет)
    # остаётся на паспортном conversion_24h, а не на скалярном дефолте
    # Execution::OutcomeSource::Deterministic::DEFAULT_OUTCOME.
    def self.outcome_table(config, providers, history)
      passport = Execution::OutcomeSource::Deterministic.passport_outcome_table(providers)
      return passport unless config.outcomes.fetch('calibrate_from_history', false)

      passport.merge(history.to_outcome_table)
    end
    private_class_method :outcome_table

    def self.fallback_used(pairs, fallback_provider)
      pairs.count { |_operation, outcome| outcome.selected.name == fallback_provider }
    end
    private_class_method :fallback_used

    def self.retried(pairs)
      pairs.count do |_operation, outcome|
        outcome.attempts.count { |attempt| attempt.decision == 'selected' } > 1
      end
    end
    private_class_method :retried

    def self.max_abs_deviation_pp(distribution)
      distribution.values.map { |entry| entry.fetch('deviation_pp').abs }.max || 0.0
    end
    private_class_method :max_abs_deviation_pp
  end
end
