# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по договорным обязательствам об обороте: «не меньше двух
    # миллионов в сутки на этого провайдера», «не больше пяти на того».
    #
    # Три группы, порядок между ними важнее различий внутри:
    #
    #   0. не добрал минимум      — наверх
    #   1. в комфортной зоне      — середина
    #   2. подошёл к максимуму    — вниз
    #
    # Внутри первой группы раньше тот, кто дальше от минимума, внутри третьей —
    # у кого больше запаса до потолка. «Подошёл к максимуму» — 90% лимита,
    # порог проверяется целочисленно (оборот × 10 ≥ максимум × 9).
    #
    # Оборот — дневной снапшот провайдера плюс то, что добавил текущий прогон:
    # стратегия видит только счётчики долей, не полное состояние.
    #
    # Отсутствующий минимум или максимум означает, что обязательства нет, а не
    # что оно нулевое: такой провайдер всегда в средней группе.
    class Obligations < Base
      MAX_THRESHOLD_NUMERATOR = 9
      MAX_THRESHOLD_DENOMINATOR = 10

      def rank(candidates, _operation, state)
        candidates.sort { |left, right| compare(left, right, state) }
      end

      def name = 'obligations'

      def explain(ranked, _operation, state)
        winner = ranked.first
        winner_text = "#{winner.name} оборот #{turnover(winner, state)}"
        return "obligations: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "obligations: #{winner_text} против #{other.name} оборот #{turnover(other, state)}"
      end

      private

      def compare(left, right, state)
        key(left, state) <=> key(right, state)
      end

      def key(provider, state)
        [tier(provider, state), secondary(provider, state), provider.name]
      end

      def tier(provider, state)
        return 0 if under_min?(provider, state)
        return 2 if near_max?(provider, state)

        1
      end

      def secondary(provider, state)
        min = provider.daily_turnover_min
        max = provider.daily_turnover_max
        current = turnover(provider, state)
        return current - min if under_min?(provider, state)
        return max - current if near_max?(provider, state)

        0
      end

      def under_min?(provider, state)
        min = provider.daily_turnover_min
        !min.nil? && turnover(provider, state) < min
      end

      def near_max?(provider, state)
        max = provider.daily_turnover_max
        return false if max.nil?

        turnover(provider, state) * MAX_THRESHOLD_DENOMINATOR >= max * MAX_THRESHOLD_NUMERATOR
      end

      def turnover(provider, state)
        provider.daily_approved_amount.to_i + state.volume_units(provider)
      end
    end

    register('obligations', Obligations)
  end
end
