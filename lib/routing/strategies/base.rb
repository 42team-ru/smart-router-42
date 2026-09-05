# frozen_string_literal: true

module Routing
  module Strategies
    # Общий контракт стратегий ранжирования: «кого из уже допущенных
    # предпочесть». Стратегия не решает, кому можно, — вернуть в игру
    # отсечённого провайдера она не вправе.
    #
    # Стратегия УПОРЯДОЧИВАЕТ, а не выбирает одного: первый элемент — основной
    # выбор, весь список — каскад на случай отказа.
    #
    # rank обязан вернуть перестановку входного списка (не добавить, не
    # удалить, не подменить) — Planner сверяет состав до и после и падает с
    # именем виновной стратегии, если это не так.
    #
    # Два сквозных запрета: не заглядывать в будущие заявки очереди (обработка
    # онлайновая) и не сравнивать дроби через float, только перекрёстным
    # умножением целых — иначе побайтовая воспроизводимость рассыпается на
    # разных машинах.
    #
    # explain попадает в attempts и объясняет жюри выбор — без чисел не
    # принимается.
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
