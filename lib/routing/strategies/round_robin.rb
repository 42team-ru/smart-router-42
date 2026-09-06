# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Раздаёт заявки по кругу: провайдеры по алфавиту, каждая следующая заявка
    # начинает список со следующего из них. Ни долей, ни приоритетов.
    #
    # В бою не используется, нужна как точка отсчёта в блоке comparison: на
    # публичной очереди ротация даёт 10 п.п. отклонения от достижимого
    # распределения, count_share — 0.
    #
    # Объект обязан быть без памяти: смещение берётся из счётчика прогона, а не
    # из поля внутри стратегии, иначе повторный прогон в блоке сравнения начался
    # бы с другой позиции. Алфавитная сортировка перед ротацией — по той же
    # причине: порядок чтения снапшота не гарантирован.
    class RoundRobin < Base
      def rank(candidates, _operation, state)
        return [] if candidates.empty?

        base = candidates.sort_by(&:name)
        offset = state.total_count_units % base.size
        base.rotate(offset)
      end

      def name = 'round_robin'

      def explain(ranked, _operation, state)
        base = ranked.sort_by(&:name)
        offset = base.empty? ? 0 : state.total_count_units % base.size
        winner = ranked.first
        "round_robin: позиция #{offset + 1} из #{base.size} допустимых, первым #{winner.name}"
      end
    end

    register('round_robin', RoundRobin)
  end
end
