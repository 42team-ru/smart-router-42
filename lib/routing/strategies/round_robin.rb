# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Раздаёт заявки по кругу, никого не выделяя.
    #
    # Самое наивное из разумных правил: провайдеры выстраиваются по алфавиту, и
    # каждая следующая заявка начинает список со следующего из них. Ни целевых
    # долей, ни приоритетов, ни конверсии, ни загрузки — просто ротация.
    #
    # В бою не используется намеренно. Она нужна как точка отсчёта: без неё
    # утверждение «наш аллокатор хорошо держит целевые доли» не подкреплено
    # ничем. С ней это измеримо — на публичной очереди ротация даёт 40 п.п.
    # отклонения от достижимого распределения, count_share даёт 0. Разница и
    # есть ответ на вопрос, зачем нужен алгоритм сложнее ротации.
    #
    # Отсюда требование, которого нет у остальных стратегий: объект обязан быть
    # без памяти. Смещение берётся из счётчика прогона, а не из поля внутри
    # стратегии, — иначе повторный прогон того же варианта в блоке сравнения
    # начался бы с другой позиции и дал другие числа. Алфавитная сортировка
    # перед ротацией нужна по той же причине: опираться на порядок чтения
    # снапшота нельзя.
    #
    # Дальше по коду: секция comparison в отчёте — где эта стратегия гоняется
    # рядом с боевой и превращается в таблицу сравнения.
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
