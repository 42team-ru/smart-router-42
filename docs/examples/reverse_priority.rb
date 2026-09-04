# frozen_string_literal: true

# Демонстрационная стратегия для CFG-3: «новая стратегия = файл + строка в
# конфиге, без правок ядра». Файл лежит вне lib/, поэтому реестр его не видит;
# scripts/demo_new_strategy.sh копирует его в lib/routing/strategies/ на время
# демонстрации и удаляет обратно.
#
# Ставит каскад в порядке убывания priority — намеренно противоположно
# стратегии priority, чтобы разница в распределении была видна сразу.

require_relative '../strategies'

module Routing
  module Strategies
    class ReversePriority < Base
      def rank(candidates, _operation, _state)
        candidates.sort { |left, right| compare(left, right) }
      end

      def name = 'reverse_priority'

      def explain(ranked, _operation, _state)
        winner = ranked.first
        winner_text = "#{winner.name} priority=#{winner.priority}"
        return "reverse_priority: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "reverse_priority: #{winner_text} против #{other.name} priority=#{other.priority}"
      end

      private

      # Ничьи разрешаются по имени: сортировка обязана быть полной и
      # воспроизводимой, иначе прогон перестаёт быть детерминированным.
      def compare(left, right)
        return right.priority <=> left.priority if left.priority != right.priority

        left.name <=> right.name
      end
    end

    register('reverse_priority', ReversePriority)
  end
end
