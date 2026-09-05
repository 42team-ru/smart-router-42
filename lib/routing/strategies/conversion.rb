# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по вероятности успешной выплаты: выше конверсия — раньше.
    #
    # Смысл прямой: если провайдер доводит до успеха девять заявок из десяти,
    # а другой — семь, при прочих равных заявку стоит отдать первому. Меньше
    # отказов, короче каскад, быстрее деньги у получателя.
    #
    # Главное решение здесь — ОТКУДА берётся конверсия. Не из снапшота: поле
    # conversion_24h заявляет сам провайдер, и на наших данных оно расходится
    # с реальностью почти вдвое (payflow обещает 0.91, история даёт 0.474).
    # Цифра считается по operations_history.csv — по тому, что провайдеры
    # сделали на самом деле. Расхождение паспорта с фактом само по себе
    # попадает в рекомендации отчёта.
    #
    # Значения хранятся в целых промилле — у всех общий знаменатель 1000,
    # поэтому сравнение обходится без float и без перекрёстного умножения
    # (см. Io::HistoryLoader — как считается наблюдаемая конверсия).
    class Conversion < Base
      # history — наблюдаемые конверсии, уже загруженные bin/route по пути из
      # конфига (ключ history_path). Стратегия файл не открывает: диска касается
      # только точка входа, иначе путь к данным оказался бы зашит в двух местах
      # и разъехался бы при первой же смене расположения файла.
      def self.from_config(_config, history: nil) = new(observed: history || {})

      # Без данных стратегия честно вырождается: все конверсии нулевые, порядок
      # задаёт имя провайдера. Молчаливое чтение файла «на всякий случай» здесь
      # хуже — оно скрыло бы, что данные не доехали.
      def initialize(observed: {})
        super()
        @observed = observed
      end

      def rank(candidates, _operation, _state)
        candidates.sort { |left, right| compare(left, right) }
      end

      def name = 'conversion'

      def explain(ranked, _operation, _state)
        winner = ranked.first
        winner_text = "#{winner.name} #{permille(winner)}‰"
        return "conversion: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "conversion: #{winner_text} против #{other.name} #{permille(other)}‰"
      end

      private

      def compare(left, right)
        left_value = permille(left)
        right_value = permille(right)
        return -1 if left_value > right_value
        return 1 if left_value < right_value

        left.name <=> right.name
      end

      def permille(provider)
        (@observed.fetch(provider.name, 0.0) * 1000).round
      end
    end

    register('conversion', Conversion)
  end
end
