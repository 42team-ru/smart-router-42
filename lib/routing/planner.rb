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

      candidates, skipped, rate_limit_note = apply_rate_limit(candidates, skipped, operation, state)

      planning_state = state || ShareLedger.new
      choice = selector.call(candidates, operation, planning_state)
      ranked_base = choice.strategy.rank(candidates, operation, planning_state)
      validate_permutation!(candidates, ranked_base, choice.strategy)
      ranked = layers.adjust(ranked_base, operation, planning_state)
      validate_permutation!(candidates, ranked, choice.strategy)
      trace = build_trace(candidates, ranked_base, ranked, operation, planning_state, choice,
                          rate_limit_note)
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

    # Ф-4 (docs/plans/P6/README.md, вариант B; вопрос организаторам --
    # docs/QUESTIONS_FOR_EXPERTS.md, В-1): второй этап отсева, отдельно от
    # REGISTRY. Ограничение по интенсивности применяется, только если после
    # него в пуле остаётся хотя бы один внешний кандидат -- иначе оно тихо
    # разошлось бы с эталонным допуском валидатора организаторов, который про
    # интенсивность не знает. Если эксперты ответят "фильтр строгий" -- эта
    # развилка снимается одной правкой: return [ok_providers, ...] без ветки
    # "пул опустел".
    def apply_rate_limit(candidates, skipped, operation, state)
      violations = candidates.to_h do |provider|
        [provider, Constraints::RateLimit.violation(provider, operation, state)]
      end
      exceeded = violations.select { |_provider, violation| violation }
      return [candidates, skipped, nil] if exceeded.empty?

      ok_providers = candidates - exceeded.keys
      return [candidates, skipped, rate_limit_not_applied_note(exceeded)] if ok_providers.empty?

      [ok_providers, skipped + exceeded.to_a, nil]
    end

    def rate_limit_not_applied_note(exceeded)
      parts = exceeded.map { |provider, violation| "#{provider.name} #{violation.details}" }
      "rate_limit: #{parts.join('; ')}, ограничение не применено — других допустимых нет"
    end

    def validate_permutation!(candidates, ranked, selected_strategy)
      same_size = ranked.size == candidates.size
      same_names = ranked.map(&:name).sort == candidates.map(&:name).sort
      valid = same_size && same_names
      return if valid

      raise "strategy #{selected_strategy.name} returned a non-permutation"
    end

    # rubocop:disable-next Metrics/ParameterLists -- входы trace совпадают с этапами планирования.
    def build_trace(candidates, ranked_base, ranked, operation, state, choice, rate_limit_note)
      return nil if candidates.empty?

      segments = [choice.details, choice.strategy.explain(ranked_base, operation, state)]
      segments.concat(layers.explain(ranked_base, ranked, operation, state)) unless layers.empty?
      segments << rate_limit_note if rate_limit_note
      PlanTrace.new(strategy_name: choice.strategy.name, segments: segments)
    end
  end
end
