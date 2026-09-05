# frozen_string_literal: true

module Routing
  module Layers
    # Общий контракт слоёв-модификаторов: слой не строит порядок кандидатов, а
    # поправляет уже построенный. Третий уровень системы: допуск решает «кому
    # можно», стратегия — «кого первым», слой — «а вот здесь стоит подвинуть,
    # потому что есть ещё одна цель». Так несколько целей учитываются вместе,
    # не сливаясь в один непрозрачный балл, по которому не объяснишь решение.
    #
    # Каждый слой измеряет своё отклонение от своей цели: целое
    # неотрицательное число, меньше — лучше. Провайдеры сортируются по этому
    # числу, при равенстве сохраняют порядок стратегии — слой уточняет решение
    # стратегии, но не отменяет его без причины.
    #
    # Отклонение проверяется на каждом вызове (падение с именем слоя, если не
    # так): дробное открыло бы дорогу float в решающий путь, отрицательное
    # сломало бы смысл «меньше — лучше».
    #
    # Главный инвариант: слой возвращает перестановку того же списка, не
    # добавляя и не удаляя — в частности, не может вернуть в игру того, кого
    # отсёк допуск. Проверяется снаружи, в Planner, после применения всех слоёв.
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
