# frozen_string_literal: true

module Routing
  module Layers
    # Слой корректирует уже проранжированный список кандидатов.
    # Инвариант: слой не может вернуть в список того, кого отсёк допуск —
    # он только переставляет уже допущенных, ничего не добавляет и не удаляет.
    # Возвращает перестановку ranked того же размера.
    class Base
      def name
        raise NotImplementedError, "#{self.class}#name"
      end

      # Отклонение от цели: целое неотрицательное число, меньше — лучше.
      def deviation(provider, operation, state)
        raise NotImplementedError, "#{self.class}#deviation"
      end

      def explain(ranked_before, ranked_after, operation, state)
        raise NotImplementedError, "#{self.class}#explain"
      end

      def adjust(ranked, operation, state)
        raise NotImplementedError, "#{self.class}#adjust" if instance_of?(Base)

        ranked.each_with_index.sort_by do |provider, index|
          [valid_deviation(provider, operation, state), index]
        end.map(&:first)
      end

      private

      def valid_deviation(provider, operation, state)
        value = deviation(provider, operation, state)
        return value if value.is_a?(Integer) && value >= 0

        raise ArgumentError,
              "#{name} deviation must be a non-negative Integer, got #{value.inspect}"
      end
    end
  end
end
