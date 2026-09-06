# frozen_string_literal: true

module Routing
  module Layers
    # Контракт слоёв: слой не строит порядок кандидатов, а поправляет уже
    # построенный стратегией. Так несколько целей учитываются вместе, не
    # сливаясь в один общий балл.
    #
    # Каждый слой возвращает своё отклонение от своей цели: целое
    # неотрицательное, меньше — лучше. При равенстве сохраняется порядок
    # стратегии. Тип проверяется на каждом вызове: дробное пустило бы float в
    # решающий путь, отрицательное сломало бы смысл «меньше — лучше».
    #
    # Инвариант: слой возвращает перестановку того же списка и не может вернуть
    # в игру отсечённого допуском. Проверяет Planner после всех слоёв.
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
