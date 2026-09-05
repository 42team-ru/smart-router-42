# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по заранее заданному порядку провайдеров.
    #
    # Самая простая из стратегий: у каждого провайдера есть номер приоритета,
    # меньше — раньше. Никакого счёта долей и состояния, порядок один и тот же
    # для любой заявки.
    #
    # Зачем нужна, если есть умные стратегии: так работает классический каскад
    # в проде — сначала основной провайдер, при отказе резервный, потом
    # запасной. Это понятная всем модель, и её полезно уметь воспроизвести,
    # когда бизнес говорит «просто ходи по списку». Плюс она не зависит от
    # истории прогона и потому предсказуема в разборе инцидентов.
    #
    # При равных приоритетах порядок задаёт имя провайдера. Это не косметика:
    # без явного правила порядок равных зависел бы от порядка чтения снапшота,
    # а он не гарантирован — и два прогона могли бы разойтись.
    class Priority < Base
      def rank(candidates, _operation, _state)
        candidates.sort { |left, right| compare(left, right) }
      end

      def name = 'priority'

      def explain(ranked, _operation, _state)
        winner = ranked.first
        winner_text = "#{winner.name} priority=#{winner.priority}"
        return "priority: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "priority: #{winner_text} против #{other.name} priority=#{other.priority}"
      end

      private

      def compare(left, right)
        return left.priority <=> right.priority if left.priority != right.priority

        left.name <=> right.name
      end
    end

    register('priority', Priority)
  end
end
