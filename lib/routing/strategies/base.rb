# frozen_string_literal: true

module Routing
  module Strategies
    # Контракт стратегий: «кого из уже допущенных предпочесть». Стратегия
    # упорядочивает весь пул, а не выбирает одного: первый — основной выбор,
    # весь список — каскад на случай отказа.
    #
    # rank обязан вернуть перестановку входного списка; Planner сверяет состав
    # до и после и падает с именем виновной стратегии.
    #
    # Два запрета: не заглядывать в будущие заявки очереди (обработка
    # онлайновая) и не сравнивать дроби через float — только перекрёстным
    # умножением целых.
    #
    # explain попадает в attempts, поэтому обязан содержать числа.
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
