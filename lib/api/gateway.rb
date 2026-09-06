# frozen_string_literal: true

require_relative 'errors'
require_relative 'serializers'
require_relative 'stream_report_builder'
require_relative 'analytics_builder'
require_relative 'validators'
require_relative 'attempt_explainer'
require_relative '../io/providers_loader'
require_relative '../io/history_loader'
require_relative '../config/loader'
require_relative '../config/routing_config'
require_relative '../routing/assembly'
require_relative '../routing/planner'
require_relative '../routing/strategies'
require_relative '../routing/layers'
require_relative '../routing/layer_stack'
require_relative '../state/providers'
require_relative '../domain/operation'
require_relative '../execution/executor'
require_relative '../execution/outcome_source/always_ok'
require_relative '../execution/outcome_source/deterministic'
require_relative '../reporting/decisions_writer'

module Api
  # Единственная точка доступа обработчиков к состоянию и ядру. Sinatra ходит
  # только сюда: класс роутинга/executor'ы/state все инкапсулированы. При
  # реконфигурации (snapshot/config/bootstrap/reset) пересобирается pipeline и
  # чистится DB — за это отвечает gateway, а не route-handlers.
  # rubocop:disable-next Metrics/ClassLength -- один координатор поверх ядра.
  class Gateway
    attr_reader :repo, :service_config

    def initialize(service_config:, routing_config:, repo:)
      Routing::Strategies.load_all!
      Routing::Layers.load_all!
      @service_config = service_config
      @routing_config = routing_config
      @routing_config_payload = config_to_payload(routing_config)
      @repo = repo
      @snapshot_payload = nil
      @providers = nil
      @state = nil
      @gateway_name = nil
      @merchant_name = nil
      rebuild_pipeline_pieces
    end

    def load_snapshot(payload)
      snapshot_ingest(payload)
      reset_analytics_and_state
      context_ok
    end

    def apply_config(payload)
      require_snapshot!
      apply_routing_config(payload.fetch('config'))
      reset_analytics_and_state
      context_ok
    end

    def bootstrap(payload)
      snapshot_ingest(payload.fetch('snapshot'))
      apply_routing_config(payload.fetch('config'))
      reset_analytics_and_state
      context_ok
    end

    def reset
      require_snapshot!
      reset_analytics_and_state
      { 'status' => 'ok' }
    end

    def current_snapshot
      require_snapshot!
      @snapshot_payload
    end

    def current_config
      @routing_config_payload
    end

    def route(operation_hash)
      require_snapshot!
      operation = build_operation(operation_hash)
      plan = @planner.plan(operation, @state)
      raw_outcome = @executor.run(plan, operation, @state)
      outcome = AttemptExplainer.call(raw_outcome, plan, operation, @strategy, @state.shares)
      @repo.insert(
        operation: operation, outcome: outcome,
        merchant: @merchant_name, gate: @gateway_name,
        strategy: @strategy.name
      )
      Serializers.decision(operation, outcome)
    end

    def route_batch(operations)
      require_snapshot!
      decisions = []
      operations.each_with_index do |op_hash, index|
        begin
          Validators.check_operation_shape!(op_hash)
        rescue Errors::ValidationFailed => e
          raise Errors::ValidationFailed.new(
            e.message, (e.details || {}).merge(
                         failed_index: index, processed: decisions.size
                       )
          )
        end
        decisions << route(op_hash)
      end
      { 'decisions' => decisions, 'processed' => decisions.size }
    end

    def state_snapshot
      require_snapshot!
      Serializers.state(
        gateway: @gateway_name, merchant: @merchant_name,
        strategy: @strategy.name, seed: seed_int,
        providers: @providers, state: @state
      )
    end

    def report(filter = {})
      require_snapshot!
      StreamReportBuilder.build(
        repo: @repo, providers: @providers,
        strategy: @strategy.name, filter: filter, history: history_for_report
      )
    end

    def list_decisions(filter: {}, limit: 100, offset: 0)
      total = @repo.count(filter)
      items = @repo.list(filter: filter, limit: limit, offset: offset)
      next_offset = offset + items.size
      next_offset = nil if next_offset >= total
      {
        'items' => items,
        'total' => total,
        'limit' => limit,
        'offset' => offset,
        'next_offset' => next_offset
      }
    end

    def analytics_overview(filter: {}, buckets: AnalyticsBuilder::DEFAULT_BUCKETS)
      require_snapshot!
      AnalyticsBuilder.overview(repo: @repo, filter: filter, buckets: buckets)
    end

    def analytics_decisions(filter: {}, limit: 100, offset: 0)
      require_snapshot!
      total = @repo.count(filter)
      items = @repo.list_with_context(filter: filter, limit: limit, offset: offset)
      next_offset = offset + items.size
      next_offset = nil if next_offset >= total
      {
        'items' => items,
        'total' => total,
        'limit' => limit,
        'offset' => offset,
        'next_offset' => next_offset
      }
    end

    # Что вообще можно поставить в config.strategy и config.layers. Реестры
    # знают это сами, поэтому список нигде не дублируется: положили файл в
    # lib/routing/strategies — он появился в выдаче и в селекторе консоли.
    def capabilities
      {
        'strategies' => Routing::Strategies.known,
        'layers' => Routing::Layers.known,
        'fallback_provider' => @routing_config.fallback_provider,
        'retention_hours' => @service_config.retention_hours
      }
    end

    def health
      {
        'status' => 'ok',
        'snapshot_loaded' => !@providers.nil?,
        'decisions_count' => @repo.count,
        'retention_hours' => @service_config.retention_hours,
        'strategy' => @strategy&.name,
        'version' => VERSION
      }
    end

    VERSION = '0.1.0'

    private

    def require_snapshot!
      raise Errors::NoSnapshot if @providers.nil?
    end

    def snapshot_ingest(payload)
      Validators.snapshot!(payload)
      @snapshot_payload = deep_dup(payload)
      @providers = payload.fetch('providers').map do |raw|
        Io::ProvidersLoader.build_provider(raw)
      end
      @gateway_name = payload['gateway']
      @merchant_name = payload['merchant']
    end

    def apply_routing_config(cfg_hash)
      @routing_config = build_routing_config(cfg_hash)
      @routing_config_payload = deep_dup(cfg_hash)
      rebuild_pipeline_pieces
    end

    def build_routing_config(cfg_hash)
      Config::RoutingConfig.new(
        strategy: cfg_hash['strategy'],
        fallback_provider: cfg_hash['fallback_provider'],
        layers: cfg_hash['layers'] || [],
        goals: cfg_hash['goals'] || {},
        strategy_selection: cfg_hash['strategy_selection'] || {},
        outcomes: cfg_hash['outcomes'] || {},
        amount_ranges: cfg_hash['amount_ranges'] || [],
        obligations: cfg_hash['obligations'] || {},
        rate_limits: cfg_hash['rate_limits'] || {}
      )
    end

    def rebuild_pipeline_pieces
      @strategy = Routing::Assembly.strategy(config: @routing_config)
      @selector = Routing::Assembly.selector(config: @routing_config)
      @layers = Routing::Assembly.layers(config: @routing_config)
      rebuild_planner_and_executor
    end

    def rebuild_planner_and_executor
      return if @providers.nil?

      @planner = Routing::Planner.new(
        providers: @providers, strategy: @strategy, selector: @selector,
        fallback_provider: @routing_config.fallback_provider,
        layers: Routing::LayerStack.new(@layers)
      )
      @executor = Execution::Executor.new(outcomes: build_outcome_source)
    end

    def reset_analytics_and_state
      @state = @providers ? State::Providers.new(@providers) : nil
      rebuild_planner_and_executor
      @repo.clear
    end

    def build_outcome_source
      outcomes = @routing_config.outcomes || {}
      source = outcomes['source'] || 'deterministic'
      case source
      when 'always_ok'
        Execution::OutcomeSource::AlwaysOk.new
      when 'deterministic'
        Execution::OutcomeSource::Deterministic.new(
          seed: outcomes['seed'] || '42',
          outcome_table: outcome_table(outcomes)
        )
      else
        raise ArgumentError, "unknown outcomes.source #{source.inspect}"
      end
    end

    # Паспортная таблица строится всегда и для всех провайдеров -- калибровка
    # из истории (если включена) накладывается поверх, а не заменяет её:
    # провайдер без истории (например, self-provider фолбэка) обязан остаться
    # на паспортном conversion_24h, а не свалиться в скалярный дефолт
    # Execution::OutcomeSource::Deterministic::DEFAULT_OUTCOME (approved_bp: 0).
    def outcome_table(outcomes)
      passport = Execution::OutcomeSource::Deterministic.passport_outcome_table(@providers)
      return passport unless outcomes['calibrate_from_history']

      passport.merge(history_outcome_table)
    end

    # smoothing здесь всегда включён (дефолт Io::HistoryLoader) -- у
    # сервисного конфига (Config::ServiceConfig) нет своего outcomes.smoothing,
    # это настройка боевого routing.yml, а не HTTP-сервиса.
    def history_outcome_table
      Io::HistoryLoader.load(@service_config.history_path).to_outcome_table
    rescue StandardError
      {}
    end

    def history_for_report
      Io::HistoryLoader.load(@service_config.history_path)
    rescue StandardError
      Reporting::ReportBuilder::EMPTY_HISTORY
    end

    def seed_int
      raw = (@routing_config.outcomes || {})['seed'] || '42'
      Integer(raw)
    rescue ArgumentError, TypeError
      raw
    end

    def context_ok
      Serializers.context_ok(
        providers_count: @providers.size,
        gateway: @gateway_name,
        merchant: @merchant_name,
        strategy: @strategy.name
      )
    end

    def build_operation(hash)
      Domain::Operation.new(
        operation_id: hash.fetch('operation_id'),
        created_at: hash.fetch('created_at'),
        amount: hash.fetch('amount'),
        bank: hash.fetch('bank'),
        card_brand: hash['card_brand'],
        payout_requisite: hash.fetch('payout_requisite')
      )
    end

    def config_to_payload(config)
      {
        'strategy' => config.strategy,
        'layers' => config.layers,
        'goals' => config.goals,
        'strategy_selection' => config.strategy_selection,
        'outcomes' => config.outcomes,
        'amount_ranges' => config.amount_ranges,
        'obligations' => config.obligations,
        'rate_limits' => config.rate_limits,
        'fallback_provider' => config.fallback_provider
      }
    end

    def deep_dup(obj)
      Marshal.load(Marshal.dump(obj))
    end
  end
end
