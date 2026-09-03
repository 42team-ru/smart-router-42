# frozen_string_literal: true

module Routing
  module Strategies
    # Стратегия УПОРЯДОЧИВАЕТ допущенных, а не выбирает одного:
    # первый элемент — выбор, весь список — каскад.
    # Контракт: возвращает перестановку candidates. Не добавляет, не удаляет,
    # не обращается к будущим операциям очереди (обработка онлайновая).
    # Сравнение дробей — перекрёстным умножением целых, без float.
    class Base
      def rank(candidates, operation, state)
        raise NotImplementedError, "#{self.class}#rank"
      end

      def name
        raise NotImplementedError, "#{self.class}#name"
      end

      def explain(ranked, operation, state)
        raise NotImplementedError, "#{self.class}#explain"
      end
    end
  end
end
