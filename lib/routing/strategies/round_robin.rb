# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Baseline для сравнения (docs/plans/P6/P3_round_robin.md, docs/SCOPE.md §4.7):
    # круговая ротация без учёта веса, приоритета и загрузки провайдера.
    # Смещение ротации берётся из состояния прогона (`state.total_count_units`),
    # а не из счётчика внутри объекта стратегии -- сам объект обязан быть без
    # памяти, иначе два вызова сравнения из П4 разойдутся.
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
