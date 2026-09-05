# frozen_string_literal: true

module Routing
  module Layers
    # Общий контракт слоёв-модификаторов.
    #
    # Слой не строит порядок кандидатов, а поправляет уже построенный. Это
    # третий уровень системы: допуск решает «кому можно», стратегия — «кого
    # первым», слой — «а вот здесь стоит подвинуть, потому что есть ещё одна
    # цель». Так несколько целей учитываются вместе, не сливаясь в один
    # непрозрачный балл, по которому потом не объяснишь ни одного решения.
    #
    # Каждый слой измеряет своё отклонение от своей цели: целое
    # неотрицательное число, меньше — лучше. Провайдеры сортируются по этому
    # числу, а при равенстве сохраняют порядок, заданный стратегией. Отсюда
    # свойство, ради которого всё и сделано: слой уточняет решение стратегии,
    # но не отменяет его без причины.
    #
    # Отклонение обязано быть именно неотрицательным целым — проверяется на
    # каждом вызове, с падением и именем слоя. Дробное значение открыло бы
    # дорогу float в решающий путь, отрицательное сломало бы смысл «меньше —
    # лучше».
    #
    # Главный инвариант: слой возвращает перестановку того же списка. Он не
    # вправе ни добавить провайдера, ни удалить — в частности, не может вернуть
    # в игру того, кого отсёк допуск. Это проверяется снаружи, в Planner, после
    # применения всех слоёв.
    #
    # Дальше по коду: Routing::LayerStack — порядок применения нескольких слоёв
    # и правило разрешения конфликтов между ними; Routing::Planner#plan — где
    # проверяется перестановочность результата.
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
