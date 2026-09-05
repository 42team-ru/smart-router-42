# frozen_string_literal: true

require_relative '../strategies'
require_relative '../../io/history_loader'

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
    # История читается один раз на класс и кешируется: стратегия создаётся на
    # каждый прогон, а файл один и тот же. Значения хранятся в целых промилле —
    # у всех общий знаменатель 1000, поэтому сравнение обходится без float и
    # без перекрёстного умножения.
    #
    # Дальше по коду: Io::HistoryLoader — как считается наблюдаемая конверсия;
    # Execution::OutcomeSource::Deterministic — та же калиброванная цифра
    # используется как порог при симуляции исходов.
    class Conversion < Base
      HISTORY_PATH = File.expand_path('../../../reference/data/operations_history.csv', __dir__)

      def initialize(observed: self.class.default_observed)
        super()
        @observed = observed
      end

      def self.default_observed
        @default_observed ||= Io::HistoryLoader.load(HISTORY_PATH)
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
