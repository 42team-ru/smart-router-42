# frozen_string_literal: true

require_relative 'constraints'
require_relative 'layer_stack'
require_relative 'plan_trace'
require_relative 'route_plan'
require_relative 'strategies'
require_relative 'strategies/count_share'
require_relative 'share_ledger'

module Routing
  # Строит каскад одной операции из её текущего снимка провайдеров.
  class Planner
    attr_reader :strategy

    def initialize(providers:, fallback_provider: 'spacepayments',
                   strategy: Strategies.build('count_share'), layers: LayerStack.new([]))
      @providers = providers
      @fallback_provider = fallback_provider
      @strategy = strategy
      @layers = layers
    end

    # rubocop:disable-next Metrics/MethodLength -- один линейный конвейер построения плана.
    def plan(operation, state = nil)
      candidates, skipped = external_providers.partition do |provider|
        Constraints.eligible?(provider, operation, state)
      end
      skipped = skipped.map do |provider|
        [provider, Constraints.check(provider, operation, state)]
      end

      planning_state = state || ShareLedger.new
      ranked_base = strategy.rank(candidates, operation, planning_state)
      validate_permutation!(candidates, ranked_base)
      ranked = layers.adjust(ranked_base, operation, planning_state)
      validate_permutation!(candidates, ranked)
      trace = build_trace(candidates, ranked_base, ranked, operation, planning_state)
      RoutePlan.new(operation: operation, candidates: ranked, skipped: skipped, trace: trace)
    end

    def fallback_provider_object
      providers.find { |provider| provider.name == fallback_provider }
    end

    private

    attr_reader :providers, :fallback_provider, :layers

    def external_providers
      providers.reject { |provider| provider.name == fallback_provider }
    end

    def validate_permutation!(candidates, ranked)
      same_size = ranked.size == candidates.size
      same_names = ranked.map(&:name).sort == candidates.map(&:name).sort
      valid = same_size && same_names
      return if valid

      raise "strategy #{strategy.name} returned a non-permutation"
    end

    def build_trace(candidates, ranked_base, ranked, operation, state)
      return nil if candidates.empty?

      segments = [strategy.explain(ranked_base, operation, state)]
      segments.concat(layers.explain(ranked_base, ranked, operation, state)) unless layers.empty?
      PlanTrace.new(strategy_name: strategy.name, segments: segments)
    end
  end
end
