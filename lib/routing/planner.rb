# frozen_string_literal: true

require_relative 'constraints'
require_relative 'layer_stack'
require_relative 'plan_trace'
require_relative 'route_plan'
require_relative 'selector'
require_relative 'strategies'
require_relative 'strategies/count_share'
require_relative 'share_ledger'

module Routing
  # Строит каскад одной операции из её текущего снимка провайдеров.
  class Planner
    attr_reader :strategy

    def initialize(providers:, fallback_provider: 'spacepayments',
                   strategy: Strategies.build('count_share'), selector: nil,
                   layers: LayerStack.new([]))
      @providers = providers
      @fallback_provider = fallback_provider
      @strategy = strategy
      @selector = selector || Selector::Static.new(strategy)
      @layers = layers
    end

    # rubocop:disable-next Metrics/MethodLength -- один линейный конвейер построения плана.
    # rubocop:disable-next Metrics/AbcSize -- один линейный конвейер построения плана.
    def plan(operation, state = nil)
      candidates, skipped = external_providers.partition do |provider|
        Constraints.eligible?(provider, operation, state)
      end
      skipped = skipped.map do |provider|
        [provider, Constraints.check(provider, operation, state)]
      end

      if candidates.empty?
        return RoutePlan.new(operation: operation, candidates: [], skipped: skipped, trace: nil)
      end

      planning_state = state || ShareLedger.new
      choice = selector.call(candidates, operation, planning_state)
      ranked_base = choice.strategy.rank(candidates, operation, planning_state)
      validate_permutation!(candidates, ranked_base, choice.strategy)
      ranked = layers.adjust(ranked_base, operation, planning_state)
      validate_permutation!(candidates, ranked, choice.strategy)
      trace = build_trace(candidates, ranked_base, ranked, operation, planning_state, choice)
      RoutePlan.new(operation: operation, candidates: ranked, skipped: skipped, trace: trace)
    end

    def fallback_provider_object
      providers.find { |provider| provider.name == fallback_provider }
    end

    private

    attr_reader :providers, :fallback_provider, :layers, :selector

    def external_providers
      providers.reject { |provider| provider.name == fallback_provider }
    end

    def validate_permutation!(candidates, ranked, selected_strategy)
      same_size = ranked.size == candidates.size
      same_names = ranked.map(&:name).sort == candidates.map(&:name).sort
      valid = same_size && same_names
      return if valid

      raise "strategy #{selected_strategy.name} returned a non-permutation"
    end

    # rubocop:disable-next Metrics/ParameterLists -- входы trace совпадают с этапами планирования.
    def build_trace(candidates, ranked_base, ranked, operation, state, choice)
      return nil if candidates.empty?

      segments = [choice.details, choice.strategy.explain(ranked_base, operation, state)]
      segments.concat(layers.explain(ranked_base, ranked, operation, state)) unless layers.empty?
      PlanTrace.new(strategy_name: choice.strategy.name, segments: segments)
    end
  end
end
